import AppKit
import CoreImage
import MetalKit

/// Metal canvas that draws the photo.
///
/// Only the visible area is computed. Core Image requests just the input region (ROI) needed for the output rect,
/// so zooming in doesn't develop all 45 megapixels.
/// Zoomed out, the RAW is decoded at 1/2–1/8 resolution (draft stage).
final class CanvasView: MTKView {
    var document: RawDocument? {
        didSet { fitting = true; applyFit(); needsDisplay = true }
    }
    var showOriginal = false { didSet { needsDisplay = true } }
    /// Side-by-side before/after: left half before, right half after (white line in the middle).
    var splitCompare = false { didSet { needsDisplay = true } }
    /// Layer edit: "before" is the develop result without layers (instead of the undeveloped photo)
    var beforeIsBase = false { didSet { needsDisplay = true } }
    private func beforeImage(_ doc: RawDocument, _ level: CGFloat) -> CIImage {
        beforeIsBase ? doc.imageWithoutLayers(scale: level) : doc.originalImage(scale: level)
    }
    /// Mask display: false red overlay, true grayscale (white is the effect).
    var maskGray = false { didSet { maskStyle = maskGray ? 1 : (maskStyle == 1 ? 0 : maskStyle) } }
    /// Mask display: 0 red overlay (selection), 1 grayscale, 2 on black, 3 on white, 4 red overlay (outside, quick mask)
    var maskStyle = 0 { didSet { needsDisplay = true } }
    var showClipping = false { didSet { needsDisplay = true } }
    /// Soft proof (look when exported to sRGB), gamut warning (pixels outside sRGB shown gray)
    var softProof = false { didSet { needsDisplay = true } }
    var gamutWarning = false { didSet { needsDisplay = true } }
    enum Tool: CaseIterable { case pan, zoom, crop, straighten, keystone, whiteBalance, retouch, mask, colorPick, transform, points, path, select, brush, move, gradient }
    /// Cursor tool. Hand drags to pan, zoom clicks 2× (Option zooms out).
    var tool: Tool = .pan {
        didSet {
            window?.invalidateCursorRects(for: self)
            overlay.isHidden = !(tool == .crop || tool == .straighten || tool == .keystone)
            overlay.mode = tool == .straighten ? .straighten : (tool == .keystone ? .keystone : .crop)
            retouchOverlay.isHidden = tool != .retouch
            maskOverlay.isHidden = tool != .mask
            transformOverlay.isHidden = tool != .transform
            pointsOverlay.isHidden = tool != .points
            pathOverlay.isHidden = tool != .path
            selectionTool.isHidden = tool != .select
            brushSurface.isHidden = tool != .brush
            moveSurface.isHidden = tool != .move
            gradientSurface.isHidden = tool != .gradient
            gradientSurface.needsDisplay = true
        }
    }
    /// "Single click" tools like the eyedropper. Passes image coordinates.
    var onPick: ((Tool, CGPoint) -> Void)?
    /// Layer drawn by the crop/straighten tools.
    let overlay = CropOverlayView()
    /// Layer that draws and places retouch spots.
    let retouchOverlay = RetouchOverlayView()
    /// Layer for painting layer masks.
    let maskOverlay = MaskOverlayView()
    /// Composition grid (thirds, grid). Clicks pass through.
    let gridOverlay = GridOverlayView()
    /// Free transform frame (⌘T)
    let transformOverlay = TransformOverlayView()
    /// Point-drag layer (free transform corners, warp grid, puppet pins, perspective crop, vanishing point planes, liquify brush)
    let pointsOverlay = PointsOverlayView()
    /// Pen/shape/text tool layer (Vector.swift)
    let pathOverlay = PathOverlayView()
    /// Layer-edit selection tools (StudioSelection.swift)
    let selectionTool = SelectionToolView()
    /// Layer-edit brush tools (Retouch/RetouchHost.swift)
    let brushSurface = BrushSurfaceView()
    /// Layer-edit move tool
    let moveSurface = MoveSurfaceView()
    /// Layer-edit gradient tools (Retouch/GradientTool.swift)
    let gradientSurface = GradientSurfaceView()
    /// Layer-edit selection, drawn as a marching-ants outline (source coordinates)
    var selectionMask: LayerMask? { didSet { needsDisplay = true } }
    /// Guides, measure, count layer and rulers (Workspace.swift)
    let guidesOverlay = GuidesOverlayView()
    let rulerTop = RulerView(edge: .top), rulerLeft = RulerView(edge: .left)
    var showRulers = UserDefaults.standard.bool(forKey: "view.rulers") { didSet { layoutRulers() } }
    /// Mouse moving over the photo (photo coordinates) — focus loupe
    var onHover: ((CGPoint) -> Void)?

    func layoutRulers() {
        let t = RulerView.thickness
        rulerTop.isHidden = !showRulers; rulerLeft.isHidden = !showRulers
        // The canvas extends under the glass panels, so rulers go on the work-area edge between panels (on the window edge the panels hid them).
        // The horizontal ruler runs along the bottom: at the top it sat under the floating tool bar
        let i = fitInsets
        let top = bounds.height - i.top
        rulerTop.frame = NSRect(x: i.left, y: i.bottom, width: max(bounds.width - i.left - i.right, 0), height: t)
        rulerLeft.frame = NSRect(x: i.left, y: i.bottom + t, width: t, height: max(top - t - i.bottom, 0))
        rulerTop.needsDisplay = true; rulerLeft.needsDisplay = true
    }

    override func layout() {
        super.layout()
        layoutRulers()
    }
    /// Layer mask shown as a red overlay (nil hides it).
    var maskLayerID: String? { didSet { needsDisplay = true } }
    /// Color editor "view selected color range": outside the range in gray
    var rangePreview: ColorRange? { didSet { if rangePreview != oldValue { needsDisplay = true } } }
    /// When zoom changes. percent is screen pixels per source pixel (%).
    var onZoomChange: (((fitting: Bool, percent: CGFloat)) -> Void)?
    /// Files dropped from Finder (images → image layers, RAW/folders → open). True if accepted.
    var onDropFiles: (([URL]) -> Bool)? { didSet { registerForDraggedTypes([.fileURL]) } }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDropFiles != nil && !DragFiles.urls(sender).isEmpty ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = DragFiles.urls(sender)
        return !urls.isEmpty && (onDropFiles?(urls) ?? false)
    }
    private var lastDrag: CGPoint?

    /// Color under the cursor (Display P3, 0–255). nil outside the photo.
    var onSample: (([Int]?) -> Void)?

    /// Screen points per source pixel.
    private(set) var zoom: CGFloat = 1
    /// Image point at the canvas center (source pixels, bottom is 0).
    private var center = CGPoint.zero
    /// Whether to keep fitting to the view when the window resizes.
    private var fitting = true

    private let queue = Render.queue
    private let ciContext = Render.context
    /// Display color space: follows the profile of the screen the window is on
    private var displaySpace = Render.displaySpace
    /// Channel view (0 composite, 1… channels)
    var channelView = 0 { didSet { if channelView != oldValue { needsDisplay = true } } }
    /// View as HDR: on EDR displays, keep brightness above 1.0
    var hdrView = UserDefaults.standard.bool(forKey: "view.hdr") { didSet { updateDisplaySpace() } }

    /// Switches the drawing color space and pixel format to match the display profile / HDR
    func updateDisplaySpace() {
        let screen = window?.screen ?? NSScreen.main
        let base = screen?.colorSpace?.cgColorSpace ?? Render.displaySpace
        let edr = hdrView && (screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
        let layer = self.layer as? CAMetalLayer
        if edr {
            colorPixelFormat = .rgba16Float
            displaySpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
            layer?.wantsExtendedDynamicRangeContent = true
        } else {
            colorPixelFormat = .bgra8Unorm
            displaySpace = base
            layer?.wantsExtendedDynamicRangeContent = false
        }
        layer?.colorspace = displaySpace
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenProfileNotification, object: nil)
        guard let w = window else { return }
        for n in [NSWindow.didChangeScreenNotification, NSWindow.didChangeScreenProfileNotification] {
            NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self] _ in self?.updateDisplaySpace() }
        }
        updateDisplaySpace()
    }
    private let background = CIImage(color: CIColor(red: 0.11, green: 0.11, blue: 0.12))

    /// Dev only: saves the first frame as PNG (DUOCHROME_SNAPSHOT=path).
    private var snapshotPath = ProcessInfo.processInfo.environment["DUOCHROME_SNAPSHOT"]
    /// Dev only: logs the time of each draw (DUOCHROME_BENCH=1).
    private let bench = ProcessInfo.processInfo.environment["DUOCHROME_BENCH"] != nil

    init() {
        super.init(frame: .zero, device: Render.device)
        overlay.canvas = self
        overlay.isHidden = true
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        retouchOverlay.canvas = self
        retouchOverlay.isHidden = true
        retouchOverlay.autoresizingMask = [.width, .height]
        addSubview(retouchOverlay)
        maskOverlay.canvas = self
        maskOverlay.isHidden = true
        maskOverlay.autoresizingMask = [.width, .height]
        addSubview(maskOverlay)
        transformOverlay.canvas = self
        transformOverlay.isHidden = true
        transformOverlay.autoresizingMask = [.width, .height]
        addSubview(transformOverlay)
        pointsOverlay.isHidden = true
        pointsOverlay.autoresizingMask = [.width, .height]
        addSubview(pointsOverlay)
        pathOverlay.isHidden = true
        pathOverlay.autoresizingMask = [.width, .height]
        addSubview(pathOverlay)
        selectionTool.canvas = self
        selectionTool.isHidden = true
        selectionTool.autoresizingMask = [.width, .height]
        addSubview(selectionTool)
        brushSurface.canvas = self
        brushSurface.isHidden = true
        brushSurface.autoresizingMask = [.width, .height]
        addSubview(brushSurface)
        moveSurface.isHidden = true
        moveSurface.autoresizingMask = [.width, .height]
        addSubview(moveSurface)
        gradientSurface.isHidden = true
        gradientSurface.autoresizingMask = [.width, .height]
        addSubview(gradientSurface)
        guidesOverlay.canvas = self
        guidesOverlay.autoresizingMask = [.width, .height]
        addSubview(guidesOverlay)
        for r in [rulerTop, rulerLeft] { r.canvas = self; addSubview(r) }
        gridOverlay.canvas = self
        gridOverlay.autoresizingMask = [.width, .height]
        addSubview(gridOverlay, positioned: .below, relativeTo: overlay)
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        (layer as? CAMetalLayer)?.colorspace = displaySpace
        isPaused = true
        enableSetNeedsDisplay = true
    }

    required init(coder: NSCoder) { fatalError("코드로만 만든다") }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    // MARK: - Zoom and pan

    private var backing: CGFloat { window?.backingScaleFactor ?? 2 }

    func zoomToFit() {
        fitting = true
        applyFit()
        needsDisplay = true
    }

    func zoomToActual() {
        // 1 source pixel = 1 screen pixel.
        setZoom(1 / backing, around: nil)
    }

    func zoomBy(_ factor: CGFloat) { setZoom(zoom * factor, around: nil) }

    /// Zooms to a percentage. 100% is 1 source pixel = 1 screen pixel (the layer-edit mode zoom slider).
    func setZoomPercent(_ percent: CGFloat) { setZoom(percent / 100 / backing, around: nil) }
    var zoomPercent: CGFloat { zoom * backing * 100 }

    /// Margins left empty in fit view. The canvas extends under the floating glass bars (Liquid Glass),
    /// and the fitted photo starts below the bar.
    var fitInsets = NSEdgeInsets() {
        didSet {
            if fitting { applyFit(); needsDisplay = true }
            window?.invalidateCursorRects(for: self)
            layoutRulers()
        }
    }

    private func applyFit() {
        guard let doc = document, bounds.width > 0, bounds.height > 0 else { return }
        let margin: CGFloat = 24
        // If the canvas extends under the toolbar, subtract its height (safe area) too
        let top = fitInsets.top + safeAreaInsets.top
        let area = NSRect(x: bounds.minX + fitInsets.left, y: bounds.minY + fitInsets.bottom,
                          width: bounds.width - fitInsets.left - fitInsets.right,
                          height: bounds.height - top - fitInsets.bottom)
        let w = max(area.width - margin * 2, 1), h = max(area.height - margin * 2, 1)
        zoom = min(w / doc.pixelSize.width, h / doc.pixelSize.height)
        // Center the photo in the fit area (shift by how far the area is off the view center)
        center = CGPoint(x: doc.pixelSize.width / 2 - (area.midX - bounds.midX) / zoom,
                         y: doc.pixelSize.height / 2 - (area.midY - bounds.midY) / zoom)
        reportZoom()
    }

    /// Zooms so the image point under `anchor` (view coordinates) stays put.
    private func setZoom(_ newZoom: CGFloat, around anchor: CGPoint?) {
        guard document != nil else { return }
        // If never fitted yet, the center point is (0,0). Fit first, then zoom.
        if fitting { applyFit() }
        let z = min(max(newZoom, 0.01), 32 / backing)
        let a = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let under = imagePoint(at: a)
        zoom = z
        center = CGPoint(x: under.x - (a.x - bounds.midX) / z, y: under.y - (a.y - bounds.midY) / z)
        fitting = false
        clampCenter()
        reportZoom()
        needsDisplay = true
    }

    /// Posted when the visible part of the photo changes (zoom or pan), for the navigator
    static let viewChanged = Notification.Name("CanvasView.viewChanged")

    /// Part of the photo visible between the panels (source pixels, bottom is 0), clipped to the photo
    var visibleImageRect: CGRect {
        guard let doc = document else { return .zero }
        let u = uncoveredRect
        let a = imagePoint(at: CGPoint(x: u.minX, y: u.minY)), b = imagePoint(at: CGPoint(x: u.maxX, y: u.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
            .intersection(CGRect(origin: .zero, size: doc.pixelSize))
    }

    /// Moves the view so this photo point (source pixels) is centered between the panels
    func centerOn(_ p: CGPoint) {
        guard document != nil else { return }
        let u = uncoveredRect
        // The uncovered area's center is offset from the view center by the panel widths
        center = CGPoint(x: p.x - (u.midX - bounds.midX) / zoom, y: p.y - (u.midY - bounds.midY) / zoom)
        fitting = false
        clampCenter()
        reportZoom()
        needsDisplay = true
    }

    func reportZoom() {
        NotificationCenter.default.post(name: Self.viewChanged, object: self)
        onZoomChange?((fitting, zoom * backing * 100))
        overlay.needsDisplay = true
        retouchOverlay.needsDisplay = true
        maskOverlay.needsDisplay = true
        gridOverlay.needsDisplay = true
        transformOverlay.needsDisplay = true
        pointsOverlay.needsDisplay = true
        pathOverlay.needsDisplay = true
        selectionTool.needsDisplay = true
        brushSurface.needsDisplay = true
        gradientSurface.needsDisplay = true
        guidesOverlay.needsDisplay = true
        rulerTop.needsDisplay = true; rulerLeft.needsDisplay = true
    }

    /// Image coordinates (source pixels) → view coordinates.
    func viewPoint(forImage p: CGPoint) -> CGPoint {
        CGPoint(x: bounds.midX + (p.x - center.x) * zoom, y: bounds.midY + (p.y - center.y) * zoom)
    }

    func imagePoint(at p: CGPoint) -> CGPoint {
        CGPoint(x: center.x + (p.x - bounds.midX) / zoom, y: center.y + (p.y - bounds.midY) / zoom)
    }

    private func clampCenter() {
        guard let doc = document else { return }
        center.x = min(max(center.x, 0), doc.pixelSize.width)
        center.y = min(max(center.y, 0), doc.pixelSize.height)
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), around: convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        guard document != nil else { return }
        let precise = event.hasPreciseScrollingDeltas
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
            let step = precise ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
            setZoom(zoom * (1 + step), around: convert(event.locationInWindow, from: nil))
            return
        }
        let k: CGFloat = precise ? 1 : 10
        center.x -= event.scrollingDeltaX * k / zoom
        center.y += event.scrollingDeltaY * k / zoom
        fitting = false
        clampCenter()
        NotificationCenter.default.post(name: Self.viewChanged, object: self)
        needsDisplay = true
    }

    /// Double-click toggles between fit and actual pixels.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        sample(at: p)
        onHover?(imagePoint(at: p))
    }
    override func mouseExited(with event: NSEvent) { onSample?(nil) }

    /// Reads one pixel from the draft-stage image currently on screen.
    private func sample(at p: CGPoint) {
        guard let doc = document, let onSample else { return }
        let ip = imagePoint(at: p)
        guard ip.x >= 0, ip.y >= 0, ip.x < doc.pixelSize.width, ip.y < doc.pixelSize.height else {
            onSample(nil); return
        }
        let level = previewLevel(for: zoom * backing)
        let img = showOriginal ? beforeImage(doc, level) : doc.image(scale: level)
        var px = [UInt8](repeating: 0, count: 4)
        let r = CGRect(x: (ip.x * level).rounded(.down), y: (ip.y * level).rounded(.down), width: 1, height: 1)
        ciContext.render(img, toBitmap: &px, rowBytes: 4, bounds: r, format: .RGBA8, colorSpace: displaySpace)
        onSample([Int(px[0]), Int(px[1]), Int(px[2])])
    }

    /// The center not covered by panels/top bar (edit cursors only here)
    var uncoveredRect: NSRect {
        let top = fitInsets.top + safeAreaInsets.top
        return NSRect(x: bounds.minX + fitInsets.left, y: bounds.minY + fitInsets.bottom,
                      width: max(bounds.width - fitInsets.left - fitInsets.right, 0),
                      height: max(bounds.height - top - fitInsets.bottom, 0))
    }

    override func resetCursorRects() {
        guard document != nil else { return }
        addCursorRect(uncoveredRect, cursor: tool == .pan ? .openHand : .crosshair)
    }

    override func mouseDragged(with event: NSEvent) {
        guard tool == .pan, document != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let last = lastDrag {
            center.x -= (p.x - last.x) / zoom
            center.y -= (p.y - last.y) / zoom
            fitting = false
            clampCenter()
            reportZoom()
            needsDisplay = true
        }
        lastDrag = p
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        lastDrag = nil
        if tool == .pan { NSCursor.openHand.set() }
    }

    override func mouseDown(with event: NSEvent) {
        lastDrag = convert(event.locationInWindow, from: nil)
        if tool == .whiteBalance || tool == .colorPick, document != nil {
            onPick?(tool, imagePoint(at: convert(event.locationInWindow, from: nil)))
            return
        }
        if tool == .zoom, event.clickCount == 1 {
            let factor: CGFloat = event.modifierFlags.contains(.option) ? 0.5 : 2
            setZoom(zoom * factor, around: convert(event.locationInWindow, from: nil))
            return
        }
        guard event.clickCount == 2 else { return }
        if fitting {
            setZoom(1 / backing, around: convert(event.locationInWindow, from: nil))
        } else {
            zoomToFit()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        overlay.frame = bounds
        retouchOverlay.frame = bounds
        maskOverlay.frame = bounds
        if fitting { applyFit() }
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    // MARK: - Drawing

    /// Smallest draft stage matching the screen pixel scale. Going lower gets blurry.
    private nonisolated func previewLevel(for pixelZoom: CGFloat) -> CGFloat {
        var level: CGFloat = 1
        while level > 1.0 / 8 && level / 2 >= pixelZoom { level /= 2 }
        return level
    }

    /// Small image (thumbnail) shown in the first frame right after switching photos, so the previous photo doesn't linger while the RAW decodes (~1 s).
    /// Only one frame is drawn with it, then immediately redrawn with the real image
    var placeholder: CGImage? { didSet { if placeholder != nil { needsDisplay = true } } }
    /// Number of frames drawn from the thumbnail first (for tests)
    private(set) var placeholderFrames = 0

    private func frameImage(size: CGSize) -> CIImage {
        let canvas = CGRect(origin: .zero, size: size)
        var out = background.cropped(to: canvas)
        guard let doc = document else { return out }
        if fitting { applyFit() }
        let pz = zoom * backing
        let level = previewLevel(for: pz)
        var img = showOriginal ? beforeImage(doc, level) : doc.image(scale: level)
        if let ph = placeholder {
            placeholder = nil
            placeholderFrames += 1
            let e = img.extent
            let p = CIImage(cgImage: ph)
            img = p.transformed(by: .init(scaleX: e.width / max(p.extent.width, 1), y: e.height / max(p.extent.height, 1)))
                .transformed(by: .init(translationX: e.minX, y: e.minY)).cropped(to: e)
            DispatchQueue.main.async { [weak self] in self?.needsDisplay = true }
        }
        if splitCompare && !showOriginal {
            // Overlay the before image on the left half (screen center, converted to image coordinates).
            let before = beforeImage(doc, level)
            let midX = (center.x + (bounds.midX - bounds.midX) / zoom) * level
            let left = CGRect(x: img.extent.minX, y: img.extent.minY, width: max(midX - img.extent.minX, 0), height: img.extent.height)
            let line = CIImage(color: .white).cropped(to: CGRect(x: midX - 1 / zoom * level, y: img.extent.minY,
                                                                   width: 2 / zoom * level, height: img.extent.height))
            img = line.composited(over: before.cropped(to: left)).composited(over: img)
        }
        if softProof || gamutWarning { img = Render.softProof(img, warn: gamutWarning) }
        if showClipping { img = Render.clippingOverlay(img) }
        if let r = rangePreview { img = RangeView.apply(img, r) }
        if channelView > 0 { img = ColorModes.channelView(img, mode: DocMode(rawValue: doc.settings.docMode ?? 0) ?? .rgb, channel: channelView) }
        if let id = maskLayerID, let m = doc.maskPreview(id, scale: level), maskStyle == 1 {
            img = m.applyingFilter("CIColorMatrix", parameters: [:]).cropped(to: img.extent)
        } else if let id = maskLayerID, let m = doc.maskPreview(id, scale: level), maskStyle == 2 || maskStyle == 3 {
            // Select and Mask: outside the selection shown black/white
            let bg = CIImage(color: maskStyle == 2 ? .black : .white).cropped(to: img.extent)
            img = img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: bg, kCIInputMaskImageKey: m]).cropped(to: img.extent)
        } else if let id = maskLayerID, let m0 = doc.maskPreview(id, scale: level) {
            let m = maskStyle == 4 ? m0.applyingFilter("CIColorInvert") : m0
            // Overlay the mask in translucent red.
            let red = CIImage(color: CIColor(red: 1, green: 0.1, blue: 0.1)).cropped(to: img.extent)
            let half = m.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.55, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.55, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.55, w: 0)])
            img = red.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: half])
        }
        if let sel = selectionMask, !showOriginal {
            // Marching ants: the selection edge (2 screen px, 1.5 was hard to see at fit view) filled with a black/white check
            let px = level / pz
            let m = doc.selectionPreview(sel, scale: level, base: img)
            let edge = m.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.5])
                .applyingFilter("CIMorphologyGradient", parameters: [kCIInputRadiusKey: max(px * 2, 0.75)]).cropped(to: img.extent)
            let ants = CIFilter(name: "CICheckerboardGenerator", parameters: [
                "inputCenter": CIVector(x: 0, y: 0), "inputColor0": CIColor.black, "inputColor1": CIColor.white,
                "inputWidth": max(px * 5, 0.75), "inputSharpness": 1])!.outputImage!.cropped(to: img.extent)
            img = ants.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: edge]).cropped(to: img.extent)
        }
        let s = pz / level
        let t = CGAffineTransform(a: s, b: 0, c: 0, d: s,
                                  tx: (size.width / 2 - center.x * pz).rounded(),
                                  ty: (size.height / 2 - center.y * pz).rounded())
        out = img.transformed(by: t).composited(over: out)
        return out.cropped(to: canvas)
    }

    override func draw(_ dirtyRect: NSRect) {
        BackgroundGate.touch()
        if bench { NSLog("draw start") }
        guard let drawable = currentDrawable, let buffer = queue.makeCommandBuffer() else {
            if bench { NSLog("draw skipped: no drawable") }
            return
        }
        let size = drawableSize
        let frame = frameImage(size: size)
        let dest = CIRenderDestination(width: Int(size.width), height: Int(size.height),
                                       pixelFormat: colorPixelFormat, commandBuffer: buffer,
                                       mtlTextureProvider: { drawable.texture })
        dest.colorSpace = displaySpace
        let started = CACurrentMediaTime()
        do {
            try ciContext.startTask(toRender: frame, to: dest)
        } catch {
            NSLog("render failed: \(error)")
        }
        buffer.present(drawable)
        if bench {
            let z = zoom * backing
            buffer.addCompletedHandler { _ in
                NSLog("draw %.0f ms (level 1/%.0f, zoom %.3f)", (CACurrentMediaTime() - started) * 1000,
                      1 / self.previewLevel(for: z), z)
            }
        }
        buffer.commit()

        if let path = snapshotPath, document != nil {
            snapshotPath = nil
            try? ciContext.writePNGRepresentation(of: frame, to: URL(fileURLWithPath: path),
                                                  format: .RGBA8, colorSpace: displaySpace)
        }
    }
}

/// Composition grids: thirds, grid (8 cells), golden ratio. Drawn only inside the photo frame.
final class GridOverlayView: NSView {
    enum Mode: Int, CaseIterable { case none, thirds, grid, golden }
    weak var canvas: CanvasView?
    var mode = Mode(rawValue: UserDefaults.standard.integer(forKey: "gridMode")) ?? .none {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "gridMode"); needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard mode != .none, let c = canvas, let doc = c.document else { return }
        let size = doc.pixelSize
        let a = c.viewPoint(forImage: .zero), b = c.viewPoint(forImage: CGPoint(x: size.width, y: size.height))
        let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        let fractions: [CGFloat] = switch mode {
        case .thirds: [1 / 3, 2 / 3]
        case .grid: (1..<8).map { CGFloat($0) / 8 }
        case .golden: [0.382, 0.618]
        case .none: []
        }
        let p = NSBezierPath()
        for f in fractions {
            p.move(to: CGPoint(x: r.minX + r.width * f, y: r.minY)); p.line(to: CGPoint(x: r.minX + r.width * f, y: r.maxY))
            p.move(to: CGPoint(x: r.minX, y: r.minY + r.height * f)); p.line(to: CGPoint(x: r.maxX, y: r.minY + r.height * f))
        }
        p.lineWidth = 1
        NSColor.black.withAlphaComponent(0.35).setStroke()
        p.stroke()
        let q = p.copy() as! NSBezierPath
        q.transform(using: AffineTransform(translationByX: 0.5, byY: -0.5))
        NSColor.white.withAlphaComponent(0.55).setStroke()
        q.stroke()
    }
}
