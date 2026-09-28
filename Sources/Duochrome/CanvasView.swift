import AppKit
import CoreImage
import MetalKit

/// 사진을 그리는 Metal 캔버스.
///
/// 화면에 보이는 영역만 계산한다. Core Image는 출력 사각형에서 거꾸로 필요한 입력
/// 영역(ROI)만 요청하므로, 확대했을 때 4,500만 화소 전체를 현상하지 않는다.
/// 축소했을 때는 RAW를 1/2~1/8 해상도로 풀어 쓴다(미리보기 단계).
final class CanvasView: MTKView {
    var document: RawDocument? {
        didSet { fitting = true; applyFit(); needsDisplay = true }
    }
    var showOriginal = false { didSet { needsDisplay = true } }
    /// 전후 나란히: 왼쪽 절반은 보정 전, 오른쪽은 보정 후 (가운데 흰 선).
    var splitCompare = false { didSet { needsDisplay = true } }
    /// 마스크 보기 방식: false 빨간 겹침, true 흑백 (흰색이 효과).
    var maskGray = false { didSet { maskStyle = maskGray ? 1 : (maskStyle == 1 ? 0 : maskStyle) } }
    /// 마스크 보기: 0 빨간 막(선택 영역), 1 흑백, 2 검정 위, 3 흰색 위, 4 빨간 막(선택 밖, 퀵 마스크)
    var maskStyle = 0 { didSet { needsDisplay = true } }
    var showClipping = false { didSet { needsDisplay = true } }
    /// 교정쇄 보기 (sRGB로 내보냈을 때의 모습), 색역 경고 (sRGB 밖 화소를 회색으로)
    var softProof = false { didSet { needsDisplay = true } }
    var gamutWarning = false { didSet { needsDisplay = true } }
    enum Tool: CaseIterable { case pan, zoom, crop, straighten, keystone, whiteBalance, retouch, mask, colorPick, transform, points, path }
    /// 커서 도구. 이동은 끌어서 옮기기, 확대는 눌러서 2배 (옵션을 누르면 축소).
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
        }
    }
    /// 스포이트 같은 "한 번 누르기" 도구. 이미지 좌표를 넘긴다.
    var onPick: ((Tool, CGPoint) -> Void)?
    /// 크롭·수평 도구가 그리는 층.
    let overlay = CropOverlayView()
    /// 리터칭 점을 그리고 찍는 층.
    let retouchOverlay = RetouchOverlayView()
    /// 레이어 마스크를 그리는 층.
    let maskOverlay = MaskOverlayView()
    /// 구도 격자 (3분할·격자). 누르기는 통과시킨다.
    let gridOverlay = GridOverlayView()
    /// 자유 변형 틀 (⌘T)
    let transformOverlay = TransformOverlayView()
    /// 점 끌기 층 (자유 변형 모서리·뒤틀기 격자·퍼펫 핀·원근 자르기·소실점 평면·유동화 붓)
    let pointsOverlay = PointsOverlayView()
    /// 펜·모양·글자 도구 층 (Vector.swift)
    let pathOverlay = PathOverlayView()
    /// 안내선·측정·계수 층과 눈금자 (Workspace.swift)
    let guidesOverlay = GuidesOverlayView()
    let rulerTop = RulerView(edge: .top), rulerLeft = RulerView(edge: .left)
    var showRulers = UserDefaults.standard.bool(forKey: "view.rulers") { didSet { layoutRulers() } }
    /// 마우스가 사진 위에서 움직일 때 (사진 좌표) — 초점 확인 창
    var onHover: ((CGPoint) -> Void)?

    func layoutRulers() {
        let t = RulerView.thickness
        rulerTop.isHidden = !showRulers; rulerLeft.isHidden = !showRulers
        // 캔버스는 유리 패널 밑까지 깔려 있으므로 눈금자는 패널 사이 작업 영역 가장자리에 (창 가장자리면 패널에 가렸다)
        let i = fitInsets
        let top = bounds.height - i.top
        rulerTop.frame = NSRect(x: i.left, y: top - t, width: max(bounds.width - i.left - i.right, 0), height: t)
        rulerLeft.frame = NSRect(x: i.left, y: i.bottom, width: t, height: max(top - t - i.bottom, 0))
        rulerTop.needsDisplay = true; rulerLeft.needsDisplay = true
    }

    override func layout() {
        super.layout()
        layoutRulers()
    }
    /// 빨간색으로 겹쳐 보일 레이어 마스크 (nil이면 안 보임).
    var maskLayerID: String? { didSet { needsDisplay = true } }
    /// 컬러 에디터 "선택한 색 범위 보기": 범위 밖을 회색으로
    var rangePreview: ColorRange? { didSet { if rangePreview != oldValue { needsDisplay = true } } }
    /// 배율이 바뀔 때. percent는 원본 1픽셀 대비 화면 픽셀 비율(%).
    var onZoomChange: (((fitting: Bool, percent: CGFloat)) -> Void)?
    /// Finder에서 파일을 놓았을 때 (그림 → 이미지 레이어, RAW·폴더 → 열기). 참이면 받았다.
    var onDropFiles: (([URL]) -> Bool)? { didSet { registerForDraggedTypes([.fileURL]) } }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDropFiles != nil && !DragFiles.urls(sender).isEmpty ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = DragFiles.urls(sender)
        return !urls.isEmpty && (onDropFiles?(urls) ?? false)
    }
    private var lastDrag: CGPoint?

    /// 커서 아래 색 (Display P3, 0~255). 사진 밖이면 nil.
    var onSample: (([Int]?) -> Void)?

    /// 원본 1픽셀이 화면 몇 포인트인지.
    private(set) var zoom: CGFloat = 1
    /// 캔버스 가운데에 오는 이미지 좌표(원본 픽셀, 아래가 0).
    private var center = CGPoint.zero
    /// 창 크기가 바뀌어도 계속 화면에 맞출지.
    private var fitting = true

    private let queue = Render.queue
    private let ciContext = Render.context
    /// 화면(모니터) 색 공간: 창이 있는 화면의 프로파일을 따른다
    private var displaySpace = Render.displaySpace
    /// 채널 보기 (0 합성, 1~ 채널)
    var channelView = 0 { didSet { if channelView != oldValue { needsDisplay = true } } }
    /// HDR로 보기: EDR 화면이면 1.0 넘는 밝기를 그대로
    var hdrView = UserDefaults.standard.bool(forKey: "view.hdr") { didSet { updateDisplaySpace() } }

    /// 화면 프로파일·HDR에 맞춰 그리기 색 공간과 픽셀 형식을 바꾼다
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

    /// 개발용: 첫 화면을 PNG로 저장한다 (DUOCHROME_SNAPSHOT=경로).
    private var snapshotPath = ProcessInfo.processInfo.environment["DUOCHROME_SNAPSHOT"]
    /// 개발용: 그릴 때마다 걸린 시간을 기록한다 (DUOCHROME_BENCH=1).
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

    // MARK: - 확대와 이동

    private var backing: CGFloat { window?.backingScaleFactor ?? 2 }

    func zoomToFit() {
        fitting = true
        applyFit()
        needsDisplay = true
    }

    func zoomToActual() {
        // 원본 1픽셀 = 화면 1픽셀.
        setZoom(1 / backing, around: nil)
    }

    func zoomBy(_ factor: CGFloat) { setZoom(zoom * factor, around: nil) }

    /// 배율(%)로 확대한다. 100%는 원본 1픽셀 = 화면 1픽셀 (심화 보정 모드의 확대 슬라이더).
    func setZoomPercent(_ percent: CGFloat) { setZoom(percent / 100 / backing, around: nil) }
    var zoomPercent: CGFloat { zoom * backing * 100 }

    /// 맞춤 보기에서 비워 둘 가장자리. 캔버스는 떠 있는 유리 막대 밑까지 깔리고(리퀴드 글래스),
    /// 맞춤 보기의 사진은 막대 아래에서 시작한다.
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
        // 창 막대 밑까지 깔린 캔버스면 그 높이(safe area)도 뺀다
        let top = fitInsets.top + safeAreaInsets.top
        let area = NSRect(x: bounds.minX + fitInsets.left, y: bounds.minY + fitInsets.bottom,
                          width: bounds.width - fitInsets.left - fitInsets.right,
                          height: bounds.height - top - fitInsets.bottom)
        let w = max(area.width - margin * 2, 1), h = max(area.height - margin * 2, 1)
        zoom = min(w / doc.pixelSize.width, h / doc.pixelSize.height)
        // 사진 가운데가 맞춤 영역 가운데에 오게 (영역이 뷰 가운데에서 벗어난 만큼 옮긴다)
        center = CGPoint(x: doc.pixelSize.width / 2 - (area.midX - bounds.midX) / zoom,
                         y: doc.pixelSize.height / 2 - (area.midY - bounds.midY) / zoom)
        reportZoom()
    }

    /// `anchor`(뷰 좌표) 아래의 이미지 점이 제자리에 남도록 확대한다.
    private func setZoom(_ newZoom: CGFloat, around anchor: CGPoint?) {
        guard document != nil else { return }
        // 아직 한 번도 맞추지 않았으면 가운데 점이 (0,0)이다. 먼저 맞춘 뒤 확대한다.
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

    func reportZoom() {
        onZoomChange?((fitting, zoom * backing * 100))
        overlay.needsDisplay = true
        retouchOverlay.needsDisplay = true
        maskOverlay.needsDisplay = true
        gridOverlay.needsDisplay = true
        transformOverlay.needsDisplay = true
        pointsOverlay.needsDisplay = true
        pathOverlay.needsDisplay = true
        guidesOverlay.needsDisplay = true
        rulerTop.needsDisplay = true; rulerLeft.needsDisplay = true
    }

    /// 이미지 좌표(원본 픽셀) → 뷰 좌표.
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
        needsDisplay = true
    }

    /// 두 번 누르면 화면 맞춤과 실제 픽셀을 오간다.
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

    /// 지금 화면에 쓰는 미리보기 단계 이미지에서 한 픽셀을 읽는다.
    private func sample(at p: CGPoint) {
        guard let doc = document, let onSample else { return }
        let ip = imagePoint(at: p)
        guard ip.x >= 0, ip.y >= 0, ip.x < doc.pixelSize.width, ip.y < doc.pixelSize.height else {
            onSample(nil); return
        }
        let level = previewLevel(for: zoom * backing)
        let img = showOriginal ? doc.originalImage(scale: level) : doc.image(scale: level)
        var px = [UInt8](repeating: 0, count: 4)
        let r = CGRect(x: (ip.x * level).rounded(.down), y: (ip.y * level).rounded(.down), width: 1, height: 1)
        ciContext.render(img, toBitmap: &px, rowBytes: 4, bounds: r, format: .RGBA8, colorSpace: displaySpace)
        onSample([Int(px[0]), Int(px[1]), Int(px[2])])
    }

    /// 패널·윗막대에 가리지 않은 가운데 (편집 포인터는 여기서만)
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

    // MARK: - 그리기

    /// 화면 픽셀 배율에 맞는 가장 작은 미리보기 단계. 그 아래로 내려가면 흐려진다.
    private nonisolated func previewLevel(for pixelZoom: CGFloat) -> CGFloat {
        var level: CGFloat = 1
        while level > 1.0 / 8 && level / 2 >= pixelZoom { level /= 2 }
        return level
    }

    /// 사진을 막 바꿨을 때 첫 장면에 먼저 보일 작은 그림(썸네일). RAW를 푸는 동안(약 1초) 이전 사진이 남아 있지 않게.
    /// 한 장면만 이걸로 그리고 곧바로 진짜 그림으로 다시 그린다
    var placeholder: CGImage? { didSet { if placeholder != nil { needsDisplay = true } } }
    /// 썸네일로 먼저 그린 장면 수 (시험용)
    private(set) var placeholderFrames = 0

    private func frameImage(size: CGSize) -> CIImage {
        let canvas = CGRect(origin: .zero, size: size)
        var out = background.cropped(to: canvas)
        guard let doc = document else { return out }
        if fitting { applyFit() }
        let pz = zoom * backing
        let level = previewLevel(for: pz)
        var img = showOriginal ? doc.originalImage(scale: level) : doc.image(scale: level)
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
            // 보정 전을 왼쪽 절반에 겹친다 (화면 가운데 기준, 이미지 좌표로 환산).
            let before = doc.originalImage(scale: level)
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
            // 선택 및 마스크: 선택 밖을 검정·흰색으로
            let bg = CIImage(color: maskStyle == 2 ? .black : .white).cropped(to: img.extent)
            img = img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: bg, kCIInputMaskImageKey: m]).cropped(to: img.extent)
        } else if let id = maskLayerID, let m0 = doc.maskPreview(id, scale: level) {
            let m = maskStyle == 4 ? m0.applyingFilter("CIColorInvert") : m0
            // 마스크를 빨간색 반투명으로 겹친다.
            let red = CIImage(color: CIColor(red: 1, green: 0.1, blue: 0.1)).cropped(to: img.extent)
            let half = m.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.55, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.55, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.55, w: 0)])
            img = red.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: half])
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

/// 구도 격자: 3분할, 격자(8칸), 황금 분할. 사진 틀 안에만 그린다.
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
