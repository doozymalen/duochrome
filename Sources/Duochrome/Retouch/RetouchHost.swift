import AppKit

/// Canvas layer for brush tools (dodge/burn and the other adjustment brushes, mask brush): draws the brush circle,
/// and hands the stroke over in source coordinates while it is painted (so the photo updates live) and when it ends.
/// ⌥ while painting erases.
final class BrushSurfaceView: NSView {
    weak var canvas: CanvasView?
    var toView: ((CGPoint) -> CGPoint)?
    var fromView: ((CGPoint) -> CGPoint)?
    /// Brush radius (source pixels)
    var radius: CGFloat = 120 { didSet { needsDisplay = true } }
    /// Stroke so far: points, erasing, still painting
    var onStroke: (([CGPoint], Bool, Bool) -> Void)?
    /// Brushes that are too slow to redo on every move (AI remove) only get the finished stroke
    var liveUpdates = true
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
        if liveUpdates, let f = fromView { onStroke?([f(p)], erasing, true) }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hover = p
        if let l = pts.last, hypot(p.x - l.x, p.y - l.y) >= max(viewRadius / 4, 2) {
            pts.append(p)
            if liveUpdates, let f = fromView { onStroke?(pts.map(f), erasing, true) }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = pts
        pts = []
        needsDisplay = true
        guard !p.isEmpty, let f = fromView else { return }
        onStroke?(p.map(f), erasing, false)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Live brushes show the result on the photo; the others show the stroke until it is applied
        if !pts.isEmpty, !liveUpdates {
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
        b.onStroke = { [weak self] pts, erase, painting in self?.retouchStroke(pts, erase: erase, painting: painting) }
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
            c.brushSurface.liveUpdates = true
            enterTool(photo == nil ? .pan : .brush)
        case .distort:
            // Liquify strokes on a photo layer (made from the current look on the first stroke); Return or esc ends it
            let kinds = ["liqPush": 0, "liqBloat": 1, "liqPucker": 2, "liqTwirl": 3, "liqReconstruct": 5]
            if photo == nil { enterTool(.pan) } else {
                liquify(tool: kinds[tool.id] ?? 0)
                // The tool stays picked like a brush: an instruction only, no done button
                retouchEditor.canvasBar.show("끌어서 칠합니다 · 붓 크기 [ ]", [])
            }
        case .gradient:
            c.gradientSurface.kind = tool.id == "gradRadial" ? .radial : .linear
            enterTool(photo == nil ? .pan : .gradient)
        case .arrange:
            // "transform" never gets here (it is a command, RetouchEditor.selectTool)
            // Crop shows the whole frame with the crop box, like the batch-edit geometry tab (same values, same undo)
            enterTool(photo == nil || tool.id == "adjust" ? .pan : (tool.id == "crop" ? .crop : .move))
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
                c.brushSurface.liveUpdates = false
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

    /// "이 선택으로 조정 레이어 만들기" in the selection options: same as + in the layers panel
    @objc func addAdjustLayerFromSelection(_ sender: Any?) { retouchAddAdjustLayer() }

    /// + in the layers panel: a new adjustment layer on top (masked by the selection if there is one)
    func retouchAddAdjustLayer() {
        guard let doc = photo else { NSSound.beep(); return }
        layersTab.addLayer(.full, native: doc.nativeSize)
        guard var s = photo?.settings, let id = layersTab.selectedID, let i = s.layers.firstIndex(where: { $0.id == id }) else { return }
        s.layers[i].name = "조정 \(s.layers.count)"
        replaceSettings(s, recordUndo: false)
        retouchEditor.reload()
    }

    /// A brush stroke, while it is painted (painting) and when it ends: preset brushes paint their own layer,
    /// the mask brush paints the selected layer's mask. Every update starts again from the settings before the stroke,
    /// so the growing stroke is applied once and the photo shows it as it is painted; the end records one undo step.
    func retouchStroke(_ pts: [CGPoint], erase: Bool, painting: Bool = false) {
        guard photo != nil else { return }
        let t = layersTab
        let ed = retouchEditor
        var stroke = MaskStroke(points: pts.flatMap { [Double($0.x), Double($0.y)] }, radius: t.brushRadius,
                                hardness: t.brushHardness, flow: t.brushFlow, erase: erase)
        stroke.tip = nil
        let tool = ed.currentTool
        if tool == "aiRemove" || tool == "smartErase" {
            if !painting { aiRemove(strokes: [stroke], smart: tool == "smartErase") }
            return
        }
        if ed.strokeBase == nil { ed.strokeBase = photo?.settings; ed.strokeLive = false }
        defer { if !painting { ed.strokeBase = nil; ed.strokeLayerID = nil } }
        guard var s = ed.strokeBase else { return }
        var label = erase ? "마스크 지우기" : "마스크 칠하기"
        if let preset = RetouchTool.presets[tool] {
            label = preset.name
            // Continue on the selected layer if it is this brush's layer, otherwise on the top one of its kind, otherwise a new one
            let own = { (l: AdjustLayer) in l.preset == tool && l.kind == "adjust" && l.mask.kind == .brush && !l.locked }
            var i = ed.strokeLayerID.flatMap { id in s.layers.firstIndex { $0.id == id } }
                ?? t.selectedID.flatMap { id in s.layers.firstIndex { $0.id == id && own($0) } } ?? s.layers.lastIndex(where: own)
            if i == nil {
                var l = AdjustLayer(name: preset.name)
                l.preset = tool
                l.mask.kind = .brush
                RetouchTool.applyPreset(tool, to: &l)
                // With a selection, the brush stays inside it
                if let sel = studioSelection { l.mask.combos = [MaskCombo(op: .intersect, mask: simpleSelectionMask(sel))] }
                s.layers.append(l)
                ed.strokeBase = s   // the new layer is part of what later updates start from
                i = s.layers.count - 1
            }
            guard let k = i else { return }
            ed.strokeLayerID = s.layers[k].id
            s.layers[k].mask.strokes.append(stroke)
        } else {
            // Mask brush: the selected layer's mask. With no layer selected, the first stroke makes an empty adjustment layer
            // limited to where it is painted (it used to fall back to the hand tool and drag the photo around)
            if ed.strokeLayerID == nil, t.selectedID.flatMap({ id in s.layers.first { $0.id == id } }) == nil {
                var l = AdjustLayer(name: "조정 \(s.layers.count + 1)")
                l.mask.kind = .brush
                if let sel = studioSelection { l.mask.combos = [MaskCombo(op: .intersect, mask: simpleSelectionMask(sel))] }
                s.layers.append(l)
                ed.strokeBase = s
                ed.strokeLayerID = l.id   // selected when the stroke ends (it isn't in the document yet)
            }
            guard let id = ed.strokeLayerID ?? t.selectedID, let i = s.layers.firstIndex(where: { $0.id == id }), !s.layers[i].locked else {
                if !painting { NSSound.beep() }
                return
            }
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
                // Selection-shaped mask: strokes add to it (⌥ takes away), one combine step per paint direction.
                // Baking an inverted/refined mask happens once, into the base, so later updates reuse the file
                if m.invert || Self.isRefined(m) {
                    m = rasterizeMask(m)
                    var b = s; b.layers[i].mask = m; ed.strokeBase = b
                }
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
        }
        if painting {
            ed.strokeLive = true
            apply(s, dragging: true)
            return
        }
        // End: one undo step from before the stroke (apply keeps the settings from its first live update)
        if ed.strokeLive { apply(s, dragging: false) } else { replaceSettings(s, recordUndo: true, label: label) }
        if let id = ed.strokeLayerID, t.selectedID != id { t.select(id) }
        ed.reload()
    }

    /// A filter layer over the whole photo (or the selection), selected so its sliders show
    func retouchFilterLayer(_ name: String, _ f: (inout LocalAdjust) -> Void) {
        guard let doc = photo else { NSSound.beep(); return }
        layersTab.addLayer(.full, native: doc.nativeSize)
        guard var s = photo?.settings, let id = layersTab.selectedID, let i = s.layers.firstIndex(where: { $0.id == id }) else { return }
        s.layers[i].name = "\(name) \(s.layers.count)"
        f(&s.layers[i].adjust)
        replaceSettings(s, recordUndo: true, label: name)
        retouchEditor.reload()
    }

    /// Background blur: AI finds the subject, a blur layer goes over everything else
    func retouchBackgroundBlur() {
        addAIMaskLayer("배경 흐림", compute: { AISelect.mask($0, target: .background) }) { $0.adjust.blur = 20 }
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
