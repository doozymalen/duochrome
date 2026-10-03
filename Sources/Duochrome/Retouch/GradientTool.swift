import AppKit

/// Canvas layer for the gradient tools (linear and radial): drag on the photo to draw a new gradient layer,
/// or drag a handle of the selected layer's gradient to change it. Shapes are in source coordinates.
///
/// Linear: [x0, y0, x1, y1], full effect at the start, none at the end.
/// Radial: [cx, cy, rx, ry], full effect inside (a circle; ⌥ draws an ellipse).
final class GradientSurfaceView: NSView, PointerSource {
    enum Kind { case linear, radial }
    weak var canvas: CanvasView?
    var kind: Kind = .linear { didSet { needsDisplay = true } }
    var toView: ((CGPoint) -> CGPoint)?
    var fromView: ((CGPoint) -> CGPoint)?
    /// The selected layer's gradient of this kind (to draw its handles), nil if it has none
    var current: (() -> [Double]?)?
    /// A shape changed: values, still dragging, whether it is a new gradient
    var onChange: (([Double], Bool, Bool) -> Void)?

    private enum Grab { case new(CGPoint), start, end, center(CGPoint, [Double]), edge }
    private var grab: Grab?
    private var live: [Double]?

    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : super.hitTest(point) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(editArea, cursor: .crosshair) }
    override func updateTrackingAreas() { super.updateTrackingAreas(); installPointerTracking() }
    override func mouseMoved(with event: NSEvent) { if grab == nil { updatePointer(event) } }
    override func cursorUpdate(with event: NSEvent) { updatePointer(event) }

    /// The ends (and a radial's edge) take the drag-point ring, a radial's inner half the move arrows, elsewhere a new gradient
    func pointer(at p: NSPoint) -> NSCursor? {
        guard let v = shown(), v.count == 4 else { return .crosshair }
        if handles(v).contains(where: { hypot($0.x - p.x, $0.y - p.y) < 10 }) { return Pointers.point }
        if kind == .radial, let src = fromView?(p), insideRadial(v, src) { return Pointers.move }
        return .crosshair
    }

    private func shown() -> [Double]? { live ?? current?() }

    private func pt(_ x: Double, _ y: Double) -> CGPoint { toView?(CGPoint(x: x, y: y)) ?? CGPoint(x: x, y: y) }

    /// Handle positions in view coordinates
    private func handles(_ v: [Double]) -> [CGPoint] {
        guard v.count == 4 else { return [] }
        switch kind {
        case .linear: return [pt(v[0], v[1]), pt(v[2], v[3])]
        case .radial: return [pt(v[0], v[1]), pt(v[0] + v[2], v[1])]
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let src = fromView?(p) else { return }
        grab = .new(src)
        if let v = shown(), v.count == 4 {
            let h = handles(v)
            let near = { (q: CGPoint) in hypot(q.x - p.x, q.y - p.y) < 10 }
            switch kind {
            case .linear:
                if near(h[0]) { grab = .start } else if near(h[1]) { grab = .end }
            case .radial:
                if near(h[1]) { grab = .edge } else if near(h[0]) || insideRadial(v, src) { grab = .center(src, v) }
            }
        }
        if case .some(.new) = grab { live = nil } else { live = current?() }
    }

    private func insideRadial(_ v: [Double], _ p: CGPoint) -> Bool {
        guard v[2] > 0, v[3] > 0 else { return false }
        let dx = (Double(p.x) - v[0]) / v[2], dy = (Double(p.y) - v[1]) / v[3]
        return dx * dx + dy * dy < 0.25   // inner half: move; outside it a drag draws a new one
    }

    private func update(_ event: NSEvent, dragging: Bool) {
        guard let g = grab, let q = fromView?(convert(event.locationInWindow, from: nil)) else { return }
        let x = Double(q.x), y = Double(q.y)
        var v = live ?? [0, 0, 0, 0]
        var isNew = false
        switch g {
        case .new(let a):
            isNew = true
            let ax = Double(a.x), ay = Double(a.y)
            if kind == .linear {
                v = [ax, ay, x, y]
            } else {
                // A circle through the pointer; ⌥ makes an ellipse fitting the drag box
                let r = hypot(x - ax, y - ay)
                let ellipse = event.modifierFlags.contains(.option)
                v = [ax, ay, max(ellipse ? abs(x - ax) : r, 1), max(ellipse ? abs(y - ay) : r, 1)]
            }
            // A click without a drag is not a gradient
            if hypot(x - ax, y - ay) < 2 { if !dragging { live = nil; grab = nil; needsDisplay = true }; return }
        case .start: v[0] = x; v[1] = y
        case .end: v[2] = x; v[3] = y
        case .center(let a, let v0):
            v = v0
            v[0] = v0[0] + x - Double(a.x); v[1] = v0[1] + y - Double(a.y)
        case .edge:
            // Keep the aspect: scale both radii by the new distance on x
            let r = max(abs(x - v[0]), 1)
            let k = v[2] > 0 ? v[3] / v[2] : 1
            v[2] = r; v[3] = r * k
        }
        live = v
        needsDisplay = true
        // New gradients become a layer when the drag ends; handle drags update the layer as they go
        if isNew {
            if !dragging { onChange?(v, false, true); live = nil }
        } else {
            onChange?(v, dragging, false)
            if !dragging { live = nil }
        }
    }

    override func mouseDragged(with event: NSEvent) { update(event, dragging: true) }
    override func mouseUp(with event: NSEvent) {
        update(event, dragging: false)
        grab = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let v = shown(), v.count == 4 else { return }
        let h = handles(v)
        let path = NSBezierPath()
        switch kind {
        case .linear:
            // Start and end lines across the direction, plus the axis
            let a = h[0], b = h[1]
            let dx = b.x - a.x, dy = b.y - a.y, len = max(hypot(dx, dy), 1)
            let nx = -dy / len * 2000, ny = dx / len * 2000
            for c in [a, b] {
                path.move(to: CGPoint(x: c.x - nx, y: c.y - ny)); path.line(to: CGPoint(x: c.x + nx, y: c.y + ny))
            }
            path.move(to: a); path.line(to: b)
        case .radial:
            let c = h[0]
            let ex = pt(v[0] + v[2], v[1]), ey = pt(v[0], v[1] + v[3])
            let rx = hypot(ex.x - c.x, ex.y - c.y), ry = hypot(ey.x - c.x, ey.y - c.y)
            path.appendOval(in: CGRect(x: c.x - rx, y: c.y - ry, width: rx * 2, height: ry * 2))
        }
        path.lineWidth = 2
        NSColor.black.withAlphaComponent(0.5).setStroke(); path.stroke()
        path.lineWidth = 1
        NSColor.white.withAlphaComponent(0.9).setStroke(); path.stroke()
        for p in h {
            let dot = NSBezierPath(ovalIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
            NSColor.white.setFill(); dot.fill()
            NSColor.black.withAlphaComponent(0.6).setStroke(); dot.lineWidth = 1; dot.stroke()
        }
    }
}

extension MainWindowController {
    /// Hooks the gradient surface to the window (from setupRetouchEditor)
    func setupGradientTool() {
        let g = viewer.canvas.gradientSurface
        g.canvas = viewer.canvas
        g.toView = viewer.canvas.brushSurface.toView
        g.fromView = viewer.canvas.brushSurface.fromView
        g.current = { [weak self] in
            guard let self, let l = self.selectedGradientLayer() else { return nil }
            return l.mask.kind == .linear ? l.mask.linear : l.mask.radial
        }
        g.onChange = { [weak self] v, dragging, isNew in self?.gradientChanged(v, dragging: dragging, isNew: isNew) }
    }

    /// The selected layer, if its mask is a gradient of the kind the tool draws
    func selectedGradientLayer() -> AdjustLayer? {
        guard let id = layersTab.selectedID, let l = photo?.settings.layers.first(where: { $0.id == id }) else { return nil }
        let want: LayerMask.Kind = viewer.canvas.gradientSurface.kind == .linear ? .linear : .radial
        return l.mask.kind == want ? l : nil
    }

    private func gradientChanged(_ v: [Double], dragging: Bool, isNew: Bool) {
        guard var s = photo?.settings else { return }
        let linear = viewer.canvas.gradientSurface.kind == .linear
        if isNew {
            var l = AdjustLayer(name: linear ? "선형 그라디언트 \(s.layers.count + 1)" : "원형 그라디언트 \(s.layers.count + 1)")
            l.mask.kind = linear ? .linear : .radial
            if linear { l.mask.linear = v } else { l.mask.radial = v }
            // Starts as a darkening gradient (the usual sky/edge use); the sliders change it
            l.adjust.exposure = -0.7
            if let sel = studioSelection { l.mask.combos = [MaskCombo(op: .intersect, mask: simpleSelectionMask(sel))] }
            s.layers.append(l)
            replaceSettings(s, recordUndo: true, label: linear ? "선형 그라디언트" : "원형 그라디언트")
            layersTab.select(l.id)
            retouchEditor.reload()
            return
        }
        guard let id = layersTab.selectedID, let i = s.layers.firstIndex(where: { $0.id == id }), !s.layers[i].locked else { return }
        if linear { s.layers[i].mask.linear = v } else { s.layers[i].mask.radial = v }
        apply(s, dragging: dragging)
        if !dragging { retouchEditor.reload() }
    }
}
