import AppKit

/// Curve defined by a few points. Coordinates 0–1, kept sorted by x.
struct ToneCurve: Equatable, Codable {
    static let identityPoints = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
    /// Up to 16 points.
    static let maxPoints = 16

    var points = ToneCurve.identityPoints
    var isIdentity: Bool { points == ToneCurve.identityPoints }

    /// Monotone cubic interpolation (Fritsch–Carlson). No overshoot between points, so no tonal inversion.
    func sample(_ n: Int) -> [Float] {
        let p = points
        let k = p.count
        var d = [Double](repeating: 0, count: k - 1)
        for i in 0..<(k - 1) {
            d[i] = Double(p[i + 1].y - p[i].y) / max(Double(p[i + 1].x - p[i].x), 1e-6)
        }
        var m = [Double](repeating: 0, count: k)
        m[0] = d[0]
        m[k - 1] = d[k - 2]
        for i in 1..<(k - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
        for i in 0..<(k - 1) where d[i] == 0 {
            m[i] = 0; m[i + 1] = 0
        }
        for i in 0..<(k - 1) where d[i] != 0 {
            let a = m[i] / d[i], b = m[i + 1] / d[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                m[i] = t * a * d[i]; m[i + 1] = t * b * d[i]
            }
        }

        var out = [Float](repeating: 0, count: n)
        var seg = 0
        for j in 0..<n {
            let x = Double(j) / Double(n - 1)
            if x <= Double(p[0].x) { out[j] = Float(p[0].y); continue }
            if x >= Double(p[k - 1].x) { out[j] = Float(p[k - 1].y); continue }
            while seg < k - 2 && x > Double(p[seg + 1].x) { seg += 1 }
            let x0 = Double(p[seg].x), x1 = Double(p[seg + 1].x)
            let h = x1 - x0, t = (x - x0) / h
            let t2 = t * t, t3 = t2 * t
            let y = (2 * t3 - 3 * t2 + 1) * Double(p[seg].y) + (t3 - 2 * t2 + t) * h * m[seg]
                + (-2 * t3 + 3 * t2) * Double(p[seg + 1].y) + (t3 - t2) * h * m[seg + 1]
            out[j] = Float(min(max(y, 0), 1))
        }
        return out
    }
}

/// The four channels of the curves tool. RGB applies first, per-channel curves on top.
struct CurveSet: Equatable, Codable {
    var rgb = ToneCurve(), red = ToneCurve(), green = ToneCurve(), blue = ToneCurve()
    /// Luma curve: moves only brightness, leaving color as is.
    var luma = ToneCurve()
    var isIdentity: Bool { rgb.isIdentity && red.isIdentity && green.isIdentity && blue.isIdentity }

    static let channels: [(String, WritableKeyPath<CurveSet, ToneCurve>, NSColor)] = [
        ("RGB", \.rgb, .white),
        ("밝기", \.luma, NSColor(white: 0.75, alpha: 1)),
        ("R", \.red, NSColor(red: 1, green: 0.35, blue: 0.35, alpha: 1)),
        ("G", \.green, NSColor(red: 0.35, green: 0.9, blue: 0.4, alpha: 1)),
        ("B", \.blue, NSColor(red: 0.4, green: 0.55, blue: 1, alpha: 1)),
    ]
}

/// Curve editor. Click empty space to add a point, drag to move, double-click or drag out to delete.
final class CurveEditorView: NSView {
    var curves = CurveSet() { didSet { needsDisplay = true } }
    var channel: WritableKeyPath<CurveSet, ToneCurve> = \.rgb { didSet { needsDisplay = true } }
    var channelColor: NSColor = .white
    var histogram: [Float]? { didSet { needsDisplay = true } }
    /// (new curve, dragging)
    var onChange: ((CurveSet, Bool) -> Void)?

    private var dragIndex: Int?
    private var draggedOut = false

    override var isFlipped: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 200) }

    private var plot: NSRect { bounds.insetBy(dx: 6, dy: 6) }
    private func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: plot.minX + p.x * plot.width, y: plot.minY + p.y * plot.height)
    }
    private func toCurve(_ v: CGPoint) -> CGPoint {
        CGPoint(x: (v.x - plot.minX) / plot.width, y: (v.y - plot.minY) / plot.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()

        if let h = histogram, let top = h[1..<(h.count - 1)].max(), top > 0 {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: plot.minX, y: plot.minY))
            for (i, v) in h.enumerated() {
                path.line(to: NSPoint(x: plot.minX + plot.width * CGFloat(i) / CGFloat(h.count - 1),
                                      y: plot.minY + plot.height * CGFloat(min(sqrt(v / top), 1)) * 0.9))
            }
            path.line(to: NSPoint(x: plot.maxX, y: plot.minY))
            NSColor.white.withAlphaComponent(0.08).setFill()
            path.fill()
        }

        NSColor.white.withAlphaComponent(0.1).setStroke()
        for i in 1..<4 {
            let t = CGFloat(i) / 4
            let g = NSBezierPath()
            g.move(to: NSPoint(x: plot.minX + plot.width * t, y: plot.minY))
            g.line(to: NSPoint(x: plot.minX + plot.width * t, y: plot.maxY))
            g.move(to: NSPoint(x: plot.minX, y: plot.minY + plot.height * t))
            g.line(to: NSPoint(x: plot.maxX, y: plot.minY + plot.height * t))
            g.lineWidth = 0.5
            g.stroke()
        }
        let diag = NSBezierPath()
        diag.move(to: toView(.zero)); diag.line(to: toView(CGPoint(x: 1, y: 1)))
        diag.setLineDash([3, 3], count: 2, phase: 0)
        diag.stroke()

        let curve = curves[keyPath: channel]
        let ys = curve.sample(128)
        let line = NSBezierPath()
        for (i, y) in ys.enumerated() {
            let p = toView(CGPoint(x: CGFloat(i) / 127, y: CGFloat(y)))
            i == 0 ? line.move(to: p) : line.line(to: p)
        }
        channelColor.setStroke()
        line.lineWidth = 1.5
        line.stroke()

        for (i, p) in curve.points.enumerated() {
            let v = toView(p)
            let dot = NSBezierPath(ovalIn: NSRect(x: v.x - 4, y: v.y - 4, width: 8, height: 8))
            (i == dragIndex ? channelColor : NSColor.black).setFill()
            dot.fill()
            channelColor.setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
        }
    }

    private func hit(_ v: CGPoint) -> Int? {
        curves[keyPath: channel].points.firstIndex { hypot(toView($0).x - v.x, toView($0).y - v.y) < 8 }
    }

    override func mouseDown(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        var curve = curves[keyPath: channel]
        if let i = hit(v) {
            if event.clickCount == 2, i != 0, i != curve.points.count - 1 {
                curve.points.remove(at: i)
                curves[keyPath: channel] = curve
                onChange?(curves, false)
                return
            }
            dragIndex = i
        } else if curve.points.count < ToneCurve.maxPoints {
            var c = toCurve(v)
            c.x = min(max(c.x, 0.001), 0.999)
            c.y = min(max(c.y, 0), 1)
            let at = curve.points.firstIndex { $0.x > c.x } ?? curve.points.count
            curve.points.insert(c, at: at)
            curves[keyPath: channel] = curve
            dragIndex = at
            onChange?(curves, true)
        }
        draggedOut = false
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let i = dragIndex else { return }
        let v = convert(event.locationInWindow, from: nil)
        var curve = curves[keyPath: channel]
        let last = curve.points.count - 1
        var c = toCurve(v)
        // Interior points are deleted when dragged far up or down out of the box.
        draggedOut = i != 0 && i != last && (c.y < -0.15 || c.y > 1.15)
        c.y = min(max(c.y, 0), 1)
        // End points move horizontally too, but can't cross their neighbors.
        let lo = i == 0 ? 0 : curve.points[i - 1].x + 0.01
        let hi = i == last ? 1 : curve.points[i + 1].x - 0.01
        c.x = min(max(c.x, lo), hi)
        curve.points[i] = c
        curves[keyPath: channel] = curve
        onChange?(curves, true)
    }

    override func mouseUp(with event: NSEvent) {
        if let i = dragIndex, draggedOut {
            curves[keyPath: channel].points.remove(at: i)
        }
        dragIndex = nil
        draggedOut = false
        needsDisplay = true
        onChange?(curves, false)
    }
}
