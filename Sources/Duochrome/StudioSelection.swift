import AppKit
import CoreImage
import simd

// MARK: - Layer-edit selection
//
// In layer-edit mode the selection belongs to the document, not to a layer: selection tools draw a
// marching-ants outline, and what happens next follows the selection —
//   ⌘A select all · ⌘D deselect · ⇧⌘I invert · ⌫ clear the selected area of the selected layer ·
//   ⌘J duplicate the selected area into a new layer · new adjustment/fill/paint layers are masked by it.
// The selection is a LayerMask in source coordinates (shapes, combines, image masks, refinements),
// so it follows the photo's geometry and reuses the layer mask renderer.

/// Drag/click layer for the selection tools. Draws the shape in progress; the finished selection is drawn by the canvas.
final class SelectionToolView: NSView {
    enum Mode { case rect, ellipse, lasso, polygon, point, magnetic, quick }
    var mode: Mode = .rect { didSet { reset() } }
    weak var canvas: CanvasView?
    /// Source coordinates ↔ view coordinates
    var toView: ((CGPoint) -> CGPoint)?
    var fromView: ((CGPoint) -> CGPoint)?
    /// Snaps a view point to a nearby edge (magnetic lasso)
    var snapView: ((CGPoint) -> CGPoint)?
    /// Quick selection brush radius (source pixels)
    var brushRadius: CGFloat = 60 { didSet { needsDisplay = true } }
    /// Finished shape (source coordinates) with the modifier keys held at the start
    var onShape: ((LayerMask, NSEvent.ModifierFlags) -> Void)?
    /// Single click (magic wand, color, row, column)
    var onPoint: ((CGPoint, NSEvent.ModifierFlags) -> Void)?
    /// Quick selection stroke (source coordinates)
    var onStroke: (([CGPoint], NSEvent.ModifierFlags) -> Void)?
    /// Click without dragging in a shape tool: deselect
    var onClickEmpty: (() -> Void)?

    private var start: CGPoint?, current: CGPoint?
    private var pts: [CGPoint] = []
    private var flags: NSEvent.ModifierFlags = []
    private var hover: CGPoint?

    func reset() { start = nil; current = nil; pts = []; needsDisplay = true }

    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : super.hitTest(point) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }
    override func mouseMoved(with event: NSEvent) { hover = convert(event.locationInWindow, from: nil); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }

    private var viewRadius: CGFloat { brushRadius * (canvas?.zoom ?? 1) }

    private static func mods(_ e: NSEvent) -> NSEvent.ModifierFlags { e.modifierFlags.intersection([.shift, .option]) }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if mode == .polygon {
            if pts.count >= 3, event.clickCount >= 2 || hypot(p.x - pts[0].x, p.y - pts[0].y) < 8 {
                finish(pts)
                return
            }
            if pts.isEmpty { flags = Self.mods(event) }
            pts.append(p)
            needsDisplay = true
            return
        }
        flags = Self.mods(event)
        switch mode {
        case .point:
            if let f = fromView { onPoint?(f(p), flags) }
        case .rect, .ellipse:
            start = p; current = p
        case .lasso, .quick:
            pts = [p]
        case .magnetic:
            pts = [snapView?(p) ?? p]
        case .polygon: break
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hover = p
        switch mode {
        case .rect, .ellipse:
            guard let s = start else { return }
            // Shift pressed during the drag (not at the start) keeps it square/circular
            if event.modifierFlags.contains(.shift) && !flags.contains(.shift) {
                let d = max(abs(p.x - s.x), abs(p.y - s.y))
                current = CGPoint(x: s.x + (p.x >= s.x ? d : -d), y: s.y + (p.y >= s.y ? d : -d))
            } else {
                current = p
            }
        case .lasso:
            if let l = pts.last, hypot(p.x - l.x, p.y - l.y) >= 2 { pts.append(p) }
        case .magnetic:
            if let l = pts.last, hypot(p.x - l.x, p.y - l.y) >= 4 { pts.append(snapView?(p) ?? p) }
        case .quick:
            if let l = pts.last, hypot(p.x - l.x, p.y - l.y) >= max(viewRadius / 3, 3) { pts.append(p) }
        case .point, .polygon: return
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .rect, .ellipse:
            guard let s = start, let c = current else { return }
            start = nil; current = nil
            if abs(c.x - s.x) < 3 || abs(c.y - s.y) < 3 {
                if flags.isEmpty { onClickEmpty?() }
                needsDisplay = true
                return
            }
            finish(outline(s, c))
        case .lasso, .magnetic:
            let p = pts
            pts = []
            if p.count >= 3 { finish(p) } else if flags.isEmpty { onClickEmpty?() }
        case .quick:
            let p = pts
            pts = []
            if !p.isEmpty, let f = fromView { onStroke?(p.map(f), flags) }
        case .point, .polygon: break
        }
        needsDisplay = true
    }

    /// Rectangle or ellipse outline in view coordinates (becomes a polygon so it follows rotation and keystone)
    private func outline(_ a: CGPoint, _ b: CGPoint) -> [CGPoint] {
        let x0 = min(a.x, b.x), x1 = max(a.x, b.x), y0 = min(a.y, b.y), y1 = max(a.y, b.y)
        if mode == .rect { return [CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0), CGPoint(x: x1, y: y1), CGPoint(x: x0, y: y1)] }
        let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2, rx = (x1 - x0) / 2, ry = (y1 - y0) / 2
        return (0..<96).map { i in
            let t = Double(i) / 96 * 2 * .pi
            return CGPoint(x: cx + rx * cos(t), y: cy + ry * sin(t))
        }
    }

    private func finish(_ viewPoints: [CGPoint]) {
        pts = []
        needsDisplay = true
        guard let f = fromView, viewPoints.count >= 3 else { return }
        var m = LayerMask()
        m.kind = .polygon
        m.polygon = viewPoints.map(f).flatMap { [Double($0.x), Double($0.y)] }
        onShape?(m, flags)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        switch mode {
        case .rect, .ellipse:
            if let s = start, let c = current {
                let o = outline(s, c)
                path.move(to: o[0]); o.dropFirst().forEach { path.line(to: $0) }; path.close()
            }
        case .lasso, .magnetic:
            if pts.count > 1 { path.move(to: pts[0]); pts.dropFirst().forEach { path.line(to: $0) } }
        case .polygon:
            if !pts.isEmpty {
                path.move(to: pts[0]); pts.dropFirst().forEach { path.line(to: $0) }
                if let h = hover { path.line(to: h) }
            }
        case .quick:
            if pts.count > 0 {
                let p = NSBezierPath()
                p.move(to: pts[0]); pts.dropFirst().forEach { p.line(to: $0) }
                if pts.count == 1 { p.line(to: CGPoint(x: pts[0].x + 0.1, y: pts[0].y)) }
                p.lineWidth = max(viewRadius * 2, 2); p.lineCapStyle = .round; p.lineJoinStyle = .round
                NSColor.controlAccentColor.withAlphaComponent(0.3).setStroke()
                p.stroke()
            }
            if let h = hover {
                let c = NSBezierPath(ovalIn: CGRect(x: h.x - viewRadius, y: h.y - viewRadius, width: viewRadius * 2, height: viewRadius * 2))
                c.lineWidth = 1
                NSColor.white.withAlphaComponent(0.8).setStroke()
                c.stroke()
            }
            return
        case .point: return
        }
        guard !path.isEmpty else { return }
        path.lineWidth = 1
        NSColor.white.setStroke()
        path.stroke()
        path.setLineDash([4, 4], count: 2, phase: 0)
        NSColor.black.setStroke()
        path.stroke()
        if mode == .polygon {
            for c in pts { NSColor.white.setFill(); NSBezierPath(ovalIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)).fill() }
        }
    }
}

extension MainWindowController {
    /// Hooks the selection layer to the photo (called once from setupStudio).
    func setupStudioSelection() {
        let t = viewer.canvas.selectionTool
        t.toView = { [weak self] p in
            guard let self, let d = self.photo else { return p }
            return self.viewer.canvas.viewPoint(forImage: d.toDisplay(p))
        }
        t.fromView = { [weak self] p in
            guard let self, let d = self.photo else { return p }
            return d.toNative(self.viewer.canvas.imagePoint(at: p))
        }
        t.snapView = { [weak self] p in
            guard let self, let doc = self.photo, let eng = self.selectionEngine else { return p }
            let native = doc.toNative(self.viewer.canvas.imagePoint(at: p))
            let snapped = eng.snap(native, radius: 12 / max(self.viewer.canvas.zoom, 0.01))
            return self.viewer.canvas.viewPoint(forImage: doc.toDisplay(snapped))
        }
        t.onShape = { [weak self] m, f in self?.addToSelection(m, flags: f) }
        t.onClickEmpty = { [weak self] in self?.studioSelection = nil }
        t.onPoint = { [weak self] p, f in
            guard let self else { return }
            switch self.retouchEditor.currentTool {
            case "selSubject": self.addAISelection(.subject)
            case "selSky": self.addAISelection(.sky)
            case "selWand": self.wandSelect(at: p, flags: f)
            case "selColor": self.colorRangeSelect(at: p, flags: f)
            case "selRow": self.rowColumnSelect(at: p, column: false, flags: f)
            case "selColumn": self.rowColumnSelect(at: p, column: true, flags: f)
            default: break
            }
        }
        t.onStroke = { [weak self] pts, f in self?.studioQuickSelect(pts, flags: f) }
    }

    /// Selection tool picked in layer edit: the canvas takes drags as selection shapes.
    func enterSelectionTool(_ id: String) {
        let t = viewer.canvas.selectionTool
        switch id {
        case "selRect": t.mode = .rect
        case "selOval": t.mode = .ellipse
        case "selFree": t.mode = .lasso
        case "selPolygon": t.mode = .polygon
        case "selMagnetic": t.mode = .magnetic
        case "selQuick": t.mode = .quick
        default: t.mode = .point   // selRow, selColumn, selWand, selColor
        }
        t.brushRadius = CGFloat(layersTab.brushRadius)
        enterTool(photo == nil ? .pan : .select)
    }

    // MARK: Combining

    /// Adds a shape to the selection: replaces it, or ⇧ adds, ⌥ subtracts, ⇧⌥ intersects (or the mode chosen in the options).
    func addToSelection(_ new: LayerMask, flags: NSEvent.ModifierFlags) {
        let op = selectionOp(flags)
        guard var cur = studioSelection, let op else {
            // Nothing to subtract from or intersect with
            if studioSelection == nil, op == .subtract || op == .intersect { return }
            studioSelection = new
            return
        }
        // Refinements and invert act after the combines — bake them first so the new shape combines with what is shown
        if cur.invert || Self.isRefined(cur) || cur.vector != nil { cur = rasterizeMask(cur) }
        let add = (new.combos ?? []).isEmpty && !new.invert && !Self.isRefined(new) ? new : rasterizeMask(new)
        cur.combos = (cur.combos ?? []) + [MaskCombo(op: op, mask: add)]
        studioSelection = cur
    }

    static func isRefined(_ m: LayerMask) -> Bool {
        (m.grow ?? 0) != 0 || (m.border ?? 0) > 0 || (m.smooth ?? 0) > 0 || m.feather > 0
            || (m.contrast ?? 0) > 0 || (m.shiftEdge ?? 0) != 0 || (m.refine ?? 0) > 0 || m.colorRange != nil || m.hasLumaRange
    }

    /// A mask with nothing to combine (the whole photo)
    static func isPlain(_ m: LayerMask) -> Bool {
        m.kind == .full && (m.combos ?? []).isEmpty && !m.invert && m.vector == nil && !isRefined(m)
    }

    /// Bakes any mask into one grayscale image mask covering the source (long side 2048)
    func rasterizeMask(_ m: LayerMask) -> LayerMask {
        guard let doc = photo else { return m }
        let n = doc.nativeSize
        let k = min(2048 / max(n.width, n.height, 1), 1)
        let w = Int((n.width * k).rounded(.down)), h = Int((n.height * k).rounded(.down))
        guard let px = maskBuffer(m, k: k, w: w, h: h), let file = Self.saveMaskPNG(px, w: w, h: h) else { return m }
        var out = LayerMask()
        out.kind = .image
        out.maskFile = file
        return out
    }

    /// Mask → 8-bit buffer (top row first) at scale k, the layout SelectionEngine uses
    func maskBuffer(_ m: LayerMask, k: CGFloat, w: Int, h: Int) -> [UInt8]? {
        guard let doc = photo, w > 0, h > 0 else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        let base = CIImage(color: .black).cropped(to: rect)
        let img = Layers.maskImage(m, scale: k, native: doc.nativeSize, shape: { i, _ in i }, base: base).cropped(to: rect)
        var px = [UInt8](repeating: 0, count: w * h)
        Render.context.render(img, toBitmap: &px, rowBytes: w, bounds: rect, format: .L8, colorSpace: nil)
        return px
    }

    static func saveMaskPNG(_ px: [UInt8], w: Int, h: Int) -> String? {
        var data = px
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let cg = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return nil }
        return try? LayerImageStore.importData(png, ext: "png")
    }

    // MARK: Pixel selections

    /// Quick selection grows from the current selection (⌥ takes away)
    func studioQuickSelect(_ pts: [CGPoint], flags: NSEvent.ModifierFlags) {
        guard let eng = selectionEngine else { NSSound.beep(); return }
        var base = studioSelection.flatMap { maskBuffer($0, k: eng.k, w: eng.w, h: eng.h) } ?? [UInt8](repeating: 0, count: eng.w * eng.h)
        eng.quickGrow(pts, radius: CGFloat(layersTab.brushRadius), into: &base, subtract: flags.contains(.option))
        guard let file = eng.save(base) else { return }
        var m = LayerMask(); m.kind = .image; m.maskFile = file
        studioSelection = m
    }

    /// Color range as a pixel selection: close to the clicked color (display values), soft within the fuzziness
    func studioColorRange(at p: CGPoint, flags: NSEvent.ModifierFlags) {
        guard let eng = selectionEngine, let (x, y) = eng.cell(p) else { NSSound.beep(); return }
        let i0 = y * eng.w + x
        let c = SIMD3<Float>(eng.rgb[i0 * 3], eng.rgb[i0 * 3 + 1], eng.rgb[i0 * 3 + 2])
        let fuzz = max(Float(UserDefaults.standard.object(forKey: "colorRange.fuzz") as? Double ?? 0.25), 0.01)
        var out = [UInt8](repeating: 0, count: eng.w * eng.h)
        for i in 0..<(eng.w * eng.h) {
            let d = simd_length(SIMD3<Float>(eng.rgb[i * 3], eng.rgb[i * 3 + 1], eng.rgb[i * 3 + 2]) - c)
            let t = min(max((d - fuzz * 0.5) / (fuzz * 0.5), 0), 1)
            out[i] = UInt8((1 - t * t * (3 - 2 * t)) * 255)
        }
        guard let file = eng.save(out) else { return }
        var m = LayerMask(); m.kind = .image; m.maskFile = file
        addToSelection(m, flags: flags)
    }

    // MARK: Commands

    @objc func selectAllStudio(_ sender: Any?) {
        guard mode == .studio, let doc = photo else { NSSound.beep(); return }
        var m = LayerMask()
        m.kind = .rect
        m.box = [0, 0, Double(doc.nativeSize.width), Double(doc.nativeSize.height)]
        studioSelection = m
        flashCommand("전체 선택")
    }

    /// ⌫ with a selection: hides the selected area of the selected layer (through its mask, so it can be brought back)
    func clearSelectedArea() {
        guard let sel = studioSelection, var s = photo?.settings else { return }
        guard let id = layersTab.selectedID, let i = s.layers.firstIndex(where: { $0.id == id }), !s.layers[i].isGroup else {
            // The background (the photo itself) can't lose pixels: work on a copy layer
            let a = NSAlert()
            a.messageText = "배경은 지울 수 없습니다"
            a.informativeText = "⌘J로 선택 영역을 새 레이어로 복제하거나, 지울 레이어를 목록에서 고르세요."
            a.runModal()
            return
        }
        guard !s.layers[i].locked else { NSSound.beep(); return }
        s.layers[i].mask = maskSubtracting(sel, from: s.layers[i].mask)
        replaceSettings(s, recordUndo: true, label: "선택 영역 지우기")
    }

    /// ⌘J with a selection: duplicates the selected layer (or the background) keeping only the selected area
    func duplicateSelectedArea() {
        guard let sel = studioSelection else { return }
        if layersTab.selectedID == nil { duplicateBackground(nil) } else { layersTab.duplicateLayer() }
        guard var s = photo?.settings, let id = layersTab.selectedID, let i = s.layers.firstIndex(where: { $0.id == id }) else { return }
        s.layers[i].mask = maskIntersecting(sel, with: s.layers[i].mask)
        replaceSettings(s, recordUndo: true, label: "선택 영역 복제")
        studioSelection = nil
    }

    func maskSubtracting(_ sel: LayerMask, from m: LayerMask) -> LayerMask {
        if Self.isPlain(m) { var r = sel; r.invert.toggle(); return r }
        var r = m.invert || Self.isRefined(m) ? rasterizeMask(m) : m
        r.combos = (r.combos ?? []) + [MaskCombo(op: .subtract, mask: simpleSelection(sel))]
        return r
    }

    func maskIntersecting(_ sel: LayerMask, with m: LayerMask) -> LayerMask {
        if Self.isPlain(m) { return sel }
        var r = m.invert || Self.isRefined(m) ? rasterizeMask(m) : m
        r.combos = (r.combos ?? []) + [MaskCombo(op: .intersect, mask: simpleSelection(sel))]
        return r
    }

    /// The selection as one shape that can be combined (combines inside combines are not rendered)
    private func simpleSelection(_ sel: LayerMask) -> LayerMask {
        (sel.combos ?? []).isEmpty && !sel.invert && !Self.isRefined(sel) ? sel : rasterizeMask(sel)
    }

    /// New adjustment/fill/paint layers made while there is a selection get it as their mask (called from apply)
    func maskingNewLayers(_ s: DevelopSettings, old: DevelopSettings) -> DevelopSettings {
        guard mode == .studio, let sel = studioSelection, s.layers.count > old.layers.count else { return s }
        let oldIDs = Set(old.layers.map(\.id))
        var out = s
        for i in out.layers.indices where !oldIDs.contains(out.layers[i].id) {
            let l = out.layers[i]
            guard ["adjust", "fill", "paint"].contains(l.kind), Self.isPlain(l.mask) else { continue }
            out.layers[i].mask = sel
        }
        return out
    }
}
