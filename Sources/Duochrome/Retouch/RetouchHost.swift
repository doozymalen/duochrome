import AppKit

/// Canvas layer for brush tools (dodge/burn and the other adjustment brushes, mask brush): draws the brush circle and
/// the stroke in progress, and hands finished strokes over in source coordinates. ⌥ while painting erases.
final class BrushSurfaceView: NSView {
    weak var canvas: CanvasView?
    var toView: ((CGPoint) -> CGPoint)?
    var fromView: ((CGPoint) -> CGPoint)?
    /// Brush radius (source pixels)
    var radius: CGFloat = 120 { didSet { needsDisplay = true } }
    var onStroke: (([CGPoint], Bool) -> Void)?
    private var pts: [CGPoint] = []
    private var hover: CGPoint?
    private var erasing = false

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

    private var viewRadius: CGFloat { radius * (canvas?.zoom ?? 1) }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        erasing = event.modifierFlags.contains(.option)
        pts = [p]
        hover = p
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hover = p
        if let l = pts.last, hypot(p.x - l.x, p.y - l.y) >= max(viewRadius / 4, 2) { pts.append(p) }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = pts
        pts = []
        needsDisplay = true
        guard !p.isEmpty, let f = fromView else { return }
        onStroke?(p.map(f), erasing)
    }

    override func draw(_ dirtyRect: NSRect) {
        if !pts.isEmpty {
            let path = NSBezierPath()
            path.move(to: pts[0]); pts.dropFirst().forEach { path.line(to: $0) }
            if pts.count == 1 { path.line(to: CGPoint(x: pts[0].x + 0.1, y: pts[0].y)) }
            path.lineWidth = viewRadius * 2
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            (erasing ? NSColor.systemBlue : NSColor.systemOrange).withAlphaComponent(0.3).setStroke()
            path.stroke()
        }
        if let h = hover {
            let c = NSBezierPath(ovalIn: CGRect(x: h.x - viewRadius, y: h.y - viewRadius, width: viewRadius * 2, height: viewRadius * 2))
            c.lineWidth = 1.5
            NSColor.black.withAlphaComponent(0.5).setStroke(); c.stroke()
            c.lineWidth = 0.75
            NSColor.white.withAlphaComponent(0.9).setStroke(); c.stroke()
        }
    }
}

extension MainWindowController {
    /// Hooks the layer editor to the window (called once from setupStudio)
    func setupRetouchEditor() {
        retouchEditor.host = self
        _ = retouchEditor.view
        let b = viewer.canvas.brushSurface
        b.toView = { [weak self] p in
            guard let self, let d = self.photo else { return p }
            return self.viewer.canvas.viewPoint(forImage: d.toDisplay(p))
        }
        b.fromView = { [weak self] p in
            guard let self, let d = self.photo else { return p }
            return d.toNative(self.viewer.canvas.imagePoint(at: p))
        }
        b.onStroke = { [weak self] pts, erase in self?.retouchStroke(pts, erase: erase) }
        let m = viewer.canvas.moveSurface
        m.fromView = b.fromView
        // Moving goes through the same code as batch edit's layer move (snapping, text anchors, shapes)
        m.onDrag = { [weak self] a, p, dragging in self?.viewer.canvas.maskOverlay.onMoveImage?(a, p, dragging) }
        setupGradientTool()
    }

    /// Picks a tool in the layer editor: exactly one canvas input goes with it
    func applyRetouchTool(_ tool: RetouchTool) {
        colorPickPurpose = 0
        let c = viewer.canvas
        c.maskOverlay.prepare = nil
        c.maskOverlay.clickMode = .none
        c.maskOverlay.quickOverride = nil
        c.guidesOverlay.tool = .none
        switch tool.group {
        case .view:
            enterTool(tool.id == "zoom" ? .zoom : .pan)
        case .select:
            enterSelectionTool(tool.id)
        case .brush:
            c.brushSurface.radius = CGFloat(layersTab.brushRadius)
            if tool.id == "maskBrush", layersTab.selectedID == nil {
                // Nothing to paint a mask on yet: keep the tool picked, the inspector says what to do
                enterTool(.pan)
            } else {
                enterTool(photo == nil ? .pan : .brush)
            }
        case .gradient:
            c.gradientSurface.kind = tool.id == "gradRadial" ? .radial : .linear
            enterTool(photo == nil ? .pan : .gradient)
        case .arrange:
            // "transform" never gets here (it is a command, RetouchEditor.selectTool)
            enterTool(photo == nil ? .pan : .move)
        case .retouch:
            switch tool.id {
            case "heal", "clone", "patch":
                var b = retouch.brush
                b.patch = tool.id == "patch"
                if !b.patch { b.kind = tool.id == "clone" ? .clone : .heal }
                retouch.brush = b
                c.retouchOverlay.brushRadius = b.radius
                c.retouchOverlay.patchMode = b.patch
                enterTool(photo == nil ? .pan : .retouch)
            default:   // aiRemove, smartErase: strokes go to the eraser
                if tool.id == "aiRemove", ProcessInfo.processInfo.environment["DUOCHROME_UITEST"] == nil { AIEngine.shared.warmUp() }
                c.brushSurface.radius = CGFloat(layersTab.brushRadius)
                enterTool(photo == nil ? .pan : .brush)
            }
        }
    }

    /// Key shortcuts and older callers pick layer-editor tools by id (older ids are mapped, unknown ones ignored)
    func retouchSelect(_ id: String) {
        let map = ["lighten": "dodge", "darken": "burn", "maskPaint": "maskBrush", "repair": "heal", "arrange": "move", "gradient": "gradLinear"]
        let t = map[id] ?? id
        guard RetouchTool.named(t) != nil else { return }
        retouchEditor.selectTool(t)
    }

    /// Brush size changed in the inspector
    func retouchBrushChanged() {
        viewer.canvas.brushSurface.radius = CGFloat(layersTab.brushRadius)
        viewer.canvas.selectionTool.brushRadius = CGFloat(layersTab.brushRadius)
    }

    /// + in the layers panel: a new adjustment layer on top (masked by the selection if there is one)
    func retouchAddAdjustLayer() {
        guard let doc = photo else { NSSound.beep(); return }
        layersTab.addLayer(.full, native: doc.nativeSize)
        guard var s = photo?.settings, let id = layersTab.selectedID, let i = s.layers.firstIndex(where: { $0.id == id }) else { return }
        s.layers[i].name = "조정 \(s.layers.count)"
        replaceSettings(s, recordUndo: false)
        retouchEditor.reload()
    }

    /// A finished brush stroke: preset brushes paint their own layer, the mask brush paints the selected layer's mask
    func retouchStroke(_ pts: [CGPoint], erase: Bool) {
        guard photo != nil else { return }
        let t = layersTab
        var stroke = MaskStroke(points: pts.flatMap { [Double($0.x), Double($0.y)] }, radius: t.brushRadius,
                                hardness: t.brushHardness, flow: t.brushFlow, erase: erase)
        stroke.tip = nil
        let tool = retouchEditor.currentTool
        if tool == "aiRemove" || tool == "smartErase" {
            aiRemove(strokes: [stroke], smart: tool == "smartErase")
            return
        }
        if let preset = RetouchTool.presets[tool] {
            guard var s = photo?.settings else { return }
            // Continue on the selected layer if it is this brush's layer, otherwise on the top one of its kind, otherwise a new one
            let own = { (l: AdjustLayer) in l.preset == tool && l.kind == "adjust" && l.mask.kind == .brush && !l.locked }
            var i = t.selectedID.flatMap { id in s.layers.firstIndex { $0.id == id && own($0) } } ?? s.layers.lastIndex(where: own)
            if i == nil {
                var l = AdjustLayer(name: preset.name)
                l.preset = tool
                l.mask.kind = .brush
                preset.adjust(&l.adjust)
                // With a selection, the brush stays inside it
                if let sel = studioSelection { l.mask.combos = [MaskCombo(op: .intersect, mask: simpleSelectionMask(sel))] }
                s.layers.append(l)
                i = s.layers.count - 1
            }
            guard let k = i else { return }
            s.layers[k].mask.strokes.append(stroke)
            let id = s.layers[k].id
            replaceSettings(s, recordUndo: true, label: preset.name)
            if t.selectedID != id { t.select(id) }
            retouchEditor.reload()
            return
        }
        // Mask brush: the selected layer's mask
        guard var s = photo?.settings, let id = t.selectedID, let i = s.layers.firstIndex(where: { $0.id == id }) else { NSSound.beep(); return }
        guard !s.layers[i].locked else { NSSound.beep(); return }
        var m = s.layers[i].mask
        if m.kind == .brush && (m.combos ?? []).isEmpty {
            m.strokes.append(stroke)
        } else if Self.isPlain(m) {
            // Whole layer: painting limits the layer to where it is painted; ⌥ instead hides the painted part
            m = LayerMask()
            m.kind = .brush
            m.brushWhite = erase
            m.strokes = [stroke]
        } else {
            // Selection-shaped mask: strokes add to it (⌥ takes away), one combine step per paint direction
            if m.invert || Self.isRefined(m) { m = rasterizeMask(m) }
            var stroke2 = stroke
            stroke2.erase = false
            let op: MaskCombo.Op = erase ? .subtract : .add
            var combos = m.combos ?? []
            if let last = combos.last, last.op == op, last.mask.kind == .brush {
                combos[combos.count - 1].mask.strokes.append(stroke2)
            } else {
                var b = LayerMask()
                b.kind = .brush
                b.strokes = [stroke2]
                combos.append(MaskCombo(op: op, mask: b))
            }
            m.combos = combos
        }
        s.layers[i].mask = m
        replaceSettings(s, recordUndo: true, label: erase ? "마스크 지우기" : "마스크 칠하기")
    }

    /// The selection as one combinable shape
    func simpleSelectionMask(_ sel: LayerMask) -> LayerMask {
        (sel.combos ?? []).isEmpty && !sel.invert && !Self.isRefined(sel) ? sel : rasterizeMask(sel)
    }
}

/// Canvas layer for the move tool: hands drags over in source coordinates (start, current, still dragging)
final class MoveSurfaceView: NSView {
    var fromView: ((CGPoint) -> CGPoint)?
    var onDrag: ((CGPoint, CGPoint, Bool) -> Void)?
    private var start: CGPoint?

    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : super.hitTest(point) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        start = fromView?(convert(event.locationInWindow, from: nil))
        NSCursor.closedHand.set()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let s = start, let p = fromView?(convert(event.locationInWindow, from: nil)) else { return }
        onDrag?(s, p, true)
    }
    override func mouseUp(with event: NSEvent) {
        defer { start = nil; NSCursor.openHand.set() }
        guard let s = start, let p = fromView?(convert(event.locationInWindow, from: nil)) else { return }
        onDrag?(s, p, false)
    }
}
