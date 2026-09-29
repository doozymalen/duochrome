import AppKit

/// Free transform frame (⌘T): changes an image layer's position, size, and rotation over the photo.
/// Corners: scale keeping aspect (⇧ free aspect) · edge midpoints: one side · inside: move · outside: rotate (⇧ 15°) · Return confirms · esc cancels.
/// All math is in source coordinates (sticks to the photo even with geometry corrections).
final class TransformOverlayView: NSView {
    weak var canvas: CanvasView?
    var image: LayerImage? { didSet { needsDisplay = true } }
    /// Image's original aspect (height/width)
    var aspect: Double = 1
    var toView: ((CGPoint) -> CGPoint)?
    var fromView: ((CGPoint) -> CGPoint)?
    var onChange: ((LayerImage, Bool) -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    private enum Grab { case move, rotate, corner(Int), edge(Int) }
    private var grab: Grab?
    private var start: LayerImage?
    private var startPoint = CGPoint.zero

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : super.hitTest(point) }

    private func height(_ im: LayerImage) -> Double { im.height ?? im.width * aspect }

    /// Four corners in source coordinates (bottom-left, bottom-right, top-right, top-left) and four edge midpoints
    private func points(_ im: LayerImage) -> (corners: [CGPoint], edges: [CGPoint]) {
        let a = im.rotation * .pi / 180
        let hw = im.width / 2, hh = height(im) / 2
        func p(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: im.cx + x * cos(a) - y * sin(a), y: im.cy + x * sin(a) + y * cos(a))
        }
        let c = [p(-hw, -hh), p(hw, -hh), p(hw, hh), p(-hw, hh)]
        let e = [p(0, -hh), p(hw, 0), p(0, hh), p(-hw, 0)]
        return (c, e)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let im = image, let toView else { return }
        let (c, e) = points(im)
        let vc = c.map(toView), ve = e.map(toView)
        let box = NSBezierPath()
        box.move(to: vc[0]); vc.dropFirst().forEach { box.line(to: $0) }; box.close()
        box.lineWidth = 1
        NSColor.white.setStroke(); box.stroke()
        box.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.black.withAlphaComponent(0.6).setStroke(); box.stroke()
        for h in vc + ve {
            let r = NSRect(x: h.x - 4, y: h.y - 4, width: 8, height: 8)
            NSColor.white.setFill(); r.fill()
            NSColor.black.withAlphaComponent(0.7).setStroke(); NSBezierPath(rect: r).stroke()
        }
        let hint = "리턴: 확정 · esc: 취소 · 바깥을 끌면 회전"
        (hint as NSString).draw(at: NSPoint(x: 12, y: bounds.maxY - 24), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white])
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let im = image, let toView, let fromView else { return }
        let p = convert(event.locationInWindow, from: nil)
        let (c, e) = points(im)
        start = im
        startPoint = fromView(p)
        if let i = c.map(toView).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) < 9 }) { grab = .corner(i); return }
        if let i = e.map(toView).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) < 9 }) { grab = .edge(i); return }
        let quad = c.map(toView)
        grab = RetouchOverlayView.inside(p, quad) ? .move : .rotate
    }

    override func mouseDragged(with event: NSEvent) {
        update(event, dragging: true)
    }

    override func mouseUp(with event: NSEvent) {
        update(event, dragging: false)
        grab = nil
    }

    private func update(_ event: NSEvent, dragging: Bool) {
        guard let s0 = start, let grab, let fromView else { return }
        let q = fromView(convert(event.locationInWindow, from: nil))
        var im = s0
        let a = s0.rotation * .pi / 180
        // source coordinates → frame-local coordinates (undo rotation)
        func local(_ p: CGPoint) -> CGPoint {
            let dx = p.x - s0.cx, dy = p.y - s0.cy
            return CGPoint(x: dx * cos(a) + dy * sin(a), y: -dx * sin(a) + dy * cos(a))
        }
        func world(_ l: CGPoint) -> CGPoint {
            CGPoint(x: s0.cx + l.x * cos(a) - l.y * sin(a), y: s0.cy + l.x * sin(a) + l.y * cos(a))
        }
        let hw = s0.width / 2, hh = height(s0) / 2
        switch grab {
        case .move:
            im.cx = s0.cx + q.x - startPoint.x
            im.cy = s0.cy + q.y - startPoint.y
        case .rotate:
            let a0 = atan2(startPoint.y - s0.cy, startPoint.x - s0.cx), a1 = atan2(q.y - s0.cy, q.x - s0.cx)
            var deg = s0.rotation + (a1 - a0) * 180 / .pi
            if event.modifierFlags.contains(.shift) { deg = (deg / 15).rounded() * 15 }
            while deg > 180 { deg -= 360 }
            while deg <= -180 { deg += 360 }
            im.rotation = deg
        case .corner(let i):
            // pin the opposite corner
            let sx: Double = [-1, 1, 1, -1][i], sy: Double = [-1, -1, 1, 1][i]
            let opp = CGPoint(x: -sx * hw, y: -sy * hh)
            let l = local(q)
            var w = max(abs(l.x - opp.x), 4), h = max(abs(l.y - opp.y), 4)
            if !event.modifierFlags.contains(.shift) {
                // Keep aspect: by length projected onto the diagonal
                let diag = CGPoint(x: sx * 2 * hw, y: sy * 2 * hh)
                let len2 = diag.x * diag.x + diag.y * diag.y
                let k = max(((l.x - opp.x) * diag.x + (l.y - opp.y) * diag.y) / len2, 0.01)
                w = 2 * hw * k; h = 2 * hh * k
            }
            let center = world(CGPoint(x: opp.x + sx * w / 2, y: opp.y + sy * h / 2))
            im.cx = center.x; im.cy = center.y
            im.width = w
            im.height = abs(h - w * aspect) < 0.5 ? nil : h
        case .edge(let i):
            let l = local(q)
            var w = 2 * hw, h = 2 * hh
            var shift = CGPoint.zero
            switch i {
            case 0: h = max(hh - l.y, 4); shift = CGPoint(x: 0, y: hh - h / 2)      // bottom edge: top edge fixed
            case 2: h = max(l.y + hh, 4); shift = CGPoint(x: 0, y: -hh + h / 2)
            case 1: w = max(l.x + hw, 4); shift = CGPoint(x: -hw + w / 2, y: 0)
            default: w = max(hw - l.x, 4); shift = CGPoint(x: hw - w / 2, y: 0)
            }
            let center = world(shift)
            im.cx = center.x; im.cy = center.y
            im.width = w
            im.height = abs(h - w * aspect) < 0.5 ? nil : h
        }
        image = im
        onChange?(im, dragging)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onCommit?()     // Return
        case 53: onCancel?()         // esc
        default: super.keyDown(with: event)
        }
    }
}

extension MainWindowController {
    /// Free transform (⌘T): shows the frame on the selected image layer.
    @objc func freeTransform(_ sender: Any?) {
        guard let doc = photo, let id = layersTab.selectedID,
              let layer = doc.settings.layers.first(where: { $0.id == id }), let im = layer.image,
              let src = Layers.sourceImage(im.file) else { NSSound.beep(); return }
        guard !layer.locked else { NSSound.beep(); return }
        let o = canvas.transformOverlay
        let before = doc.settings
        let previousTool = canvas.tool
        o.aspect = Double(src.extent.height / max(src.extent.width, 1))
        o.image = im
        o.toView = { [weak self] p in
            guard let self, let doc = self.photo else { return p }
            return self.canvas.viewPoint(forImage: doc.toDisplay(p))
        }
        o.fromView = { [weak self] p in
            guard let self, let doc = self.photo else { return p }
            return doc.toNative(self.canvas.imagePoint(at: p))
        }
        o.onChange = { [weak self] newImage, dragging in
            guard let self, var s = self.photo?.settings, let i = s.layers.firstIndex(where: { $0.id == id }) else { return }
            s.layers[i].image = newImage
            // Light while dragging; on release apply without recording (recorded once on confirm)
            self.photo?.draft = dragging
            self.photo?.settings = s
            self.canvas.needsDisplay = true
        }
        let finish: (Bool) -> Void = { [weak self] keep in
            guard let self, let doc = self.photo else { return }
            var s = doc.settings
            if !keep { s = before }
            doc.settings = before          // so the history entry is "before transform → after"
            self.enterTool(previousTool == .transform ? .pan : previousTool)
            if keep {
                self.replaceSettings(s, recordUndo: true, label: "자유 변형")
            } else {
                self.apply(before, dragging: false)
            }
            self.layersTab.sync(s)
        }
        o.onCommit = { finish(true) }
        o.onCancel = { finish(false) }
        enterTool(.transform)
        window?.makeFirstResponder(o)
    }
}
