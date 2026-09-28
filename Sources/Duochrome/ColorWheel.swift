import AppKit

/// 색 휠 하나 (3방향 색상). 각도가 색조, 가운데서 떨어진 거리가 양이다.
/// 왼쪽 호는 색의 세기(양, 위로 올리면 세지고 아래로 내리면 반대색), 오른쪽 호는 그 영역의 밝기.
/// 두 번 누르면 가운데로 돌아간다 (호를 두 번 누르면 그 호만).
final class ColorWheelView: NSView {
    var shift = ColorShift() { didSet { needsDisplay = true } }
    /// (새 값, 끄는 중인지)
    var onChange: ((ColorShift, Bool) -> Void)?
    /// 호를 그릴지 (작은 휠은 끈다)
    var showsArcs = true { didSet { needsDisplay = true } }

    private static var wheelImage: CGImage? = makeWheel(size: 220)
    /// 화면 각도 = 색조 + 90° (빨강이 위, 청록이 아래)
    static let hueOffset: CGFloat = 90

    override var intrinsicContentSize: NSSize { NSSize(width: 170, height: 140) }

    /// 색 원판 자리 (시험에서도 쓴다)
    var discRect: NSRect {
        let pad: CGFloat = showsArcs ? 24 : 3
        let d = max(min(bounds.width - pad * 2, bounds.height - 6), 10)
        return NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
    }

    // 호: 원판 바깥, 가운데에서 ±55°
    private let arcSpan: CGFloat = 55
    private var arcRadius: CGFloat { discRect.width / 2 + 13 }

    /// 호 위 값(-1~1) → 점. 왼쪽 호는 180°를 가운데로 (위가 +).
    private func arcPoint(left: Bool, value t: CGFloat) -> NSPoint {
        let deg = left ? 180 - t * arcSpan : t * arcSpan
        let a = deg * .pi / 180
        return NSPoint(x: discRect.midX + cos(a) * arcRadius, y: discRect.midY + sin(a) * arcRadius)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let img = Self.wheelImage else { return }
        let disc = discRect
        ctx.saveGState()
        ctx.addEllipse(in: disc)
        ctx.clip()
        ctx.draw(img, in: disc)
        ctx.restoreGState()
        NSColor.black.withAlphaComponent(0.35).setStroke()
        let ring = NSBezierPath(ovalIn: disc)
        ring.lineWidth = 1
        ring.stroke()

        if showsArcs {
            drawArc(left: true, top: NSColor(red: 0.95, green: 0.25, blue: 0.25, alpha: 1), value: CGFloat(shift.amount))
            drawArc(left: false, top: NSColor(white: 0.85, alpha: 1), value: CGFloat(shift.lightness))
        }

        // 가운데 십자와 손잡이
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: disc.midX - 9, y: disc.midY)); cross.line(to: NSPoint(x: disc.midX + 9, y: disc.midY))
        cross.move(to: NSPoint(x: disc.midX, y: disc.midY - 9)); cross.line(to: NSPoint(x: disc.midX, y: disc.midY + 9))
        cross.lineWidth = 1
        cross.stroke()
        let a = (CGFloat(shift.hue) + Self.hueOffset) * .pi / 180, r = CGFloat(shift.amount) * disc.width / 2
        let p = NSPoint(x: disc.midX + cos(a) * r, y: disc.midY + sin(a) * r)
        knob(at: p, radius: 8)
    }

    private func drawArc(left: Bool, top: NSColor, value: CGFloat) {
        // 아래(어두움) → 위(그 색)로 조금씩 이어 그린다
        let steps = 24
        for i in 0..<steps {
            let t0 = -1 + 2 * CGFloat(i) / CGFloat(steps), t1 = -1 + 2 * CGFloat(i + 1) / CGFloat(steps)
            let seg = NSBezierPath()
            seg.move(to: arcPoint(left: left, value: t0))
            seg.line(to: arcPoint(left: left, value: t1))
            seg.lineWidth = 3
            seg.lineCapStyle = .round
            let k = (t0 + 1) / 2
            (NSColor(white: 0.3, alpha: 1).blended(withFraction: k, of: top) ?? top).setStroke()
            seg.stroke()
        }
        // 가운데 눈금
        let mid = arcPoint(left: left, value: 0)
        let out = NSPoint(x: mid.x + (left ? -7 : 7), y: mid.y)
        let tick = NSBezierPath(); tick.move(to: mid); tick.line(to: out)
        NSColor.white.withAlphaComponent(0.3).setStroke(); tick.lineWidth = 1; tick.stroke()
        knob(at: arcPoint(left: left, value: max(-1, min(1, value))), radius: 6)
    }

    private func knob(at p: NSPoint, radius r: CGFloat) {
        let o = NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowBlurRadius = 2; sh.shadowColor = NSColor.black.withAlphaComponent(0.5); sh.set()
        NSColor(white: 0.82, alpha: 1).setFill()
        o.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: 끌기

    private enum Part { case disc, amountArc, lightArc }
    private var part: Part = .disc

    private func hitPart(_ v: NSPoint) -> Part {
        guard showsArcs else { return .disc }
        let disc = discRect
        let d = hypot(v.x - disc.midX, v.y - disc.midY)
        if d > disc.width / 2 + 4 { return v.x < disc.midX ? .amountArc : .lightArc }
        return .disc
    }

    /// 점 → 호 값 (-1~1)
    private func arcValue(_ v: NSPoint, left: Bool) -> Float {
        var deg = atan2(v.y - discRect.midY, v.x - discRect.midX) * 180 / .pi
        if left { deg = 180 - (deg < 0 ? deg + 360 : deg) }
        return Float(max(-1, min(1, deg / arcSpan)))
    }

    private func update(_ event: NSEvent, dragging: Bool) {
        let v = convert(event.locationInWindow, from: nil)
        var s = shift
        switch part {
        case .disc:
            let disc = discRect
            let dx = v.x - disc.midX, dy = v.y - disc.midY
            s.amount = Float(min(hypot(dx, dy) / (disc.width / 2), 1))
            var h = Float(atan2(dy, dx) * 180 / .pi - Self.hueOffset)
            while h < 0 { h += 360 }
            s.hue = h
        case .amountArc:
            // 아래로 내리면 반대색 쪽으로
            let t = arcValue(v, left: true)
            if t < 0, s.amount >= 0 { s.hue = (s.hue + 180).truncatingRemainder(dividingBy: 360) }
            s.amount = abs(t)
        case .lightArc:
            s.lightness = arcValue(v, left: false)
        }
        shift = s
        onChange?(s, dragging)
    }

    override func mouseDown(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        part = hitPart(v)
        if event.clickCount == 2 {
            switch part {
            case .disc: shift.hue = 0; shift.amount = 0
            case .amountArc: shift.amount = 0
            case .lightArc: shift.lightness = 0
            }
            onChange?(shift, false)
            return
        }
        update(event, dragging: true)
    }

    override func mouseDragged(with event: NSEvent) { update(event, dragging: true) }
    override func mouseUp(with event: NSEvent) { onChange?(shift, false) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    /// 색조는 각도, 채도는 반지름을 따라 늘어나는 원판 (가운데는 어두운 회색, 가장자리로 갈수록 선명하게).
    private static func makeWheel(size n: Int) -> CGImage? {
        var px = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                let dx = (Double(x) + 0.5) / Double(n) * 2 - 1
                let dy = 1 - (Double(y) + 0.5) / Double(n) * 2
                let r = min(hypot(dx, dy), 1)
                var h = atan2(dy, dx) * 180 / .pi - Double(hueOffset)
                while h < 0 { h += 360 }
                let c = NSColor(hue: h / 360, saturation: pow(r, 0.9) * 0.72, brightness: 0.3 + 0.38 * r, alpha: 1)
                let i = (y * n + x) * 4
                px[i] = UInt8(c.redComponent * 255)
                px[i + 1] = UInt8(c.greenComponent * 255)
                px[i + 2] = UInt8(c.blueComponent * 255)
                px[i + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
