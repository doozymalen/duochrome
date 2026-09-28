import AppKit

/// 레벨: 히스토그램 아래 입력 삼각 손잡이 셋(검정·중간·흰색), 그 아래 출력 막대와 손잡이 둘.
/// 값: [입력 검정, 입력 흰색, 감마, 출력 검정, 출력 흰색]. 중간 손잡이 자리 = 검정 + (흰색 − 검정) × 0.5^감마.
final class LevelsView: NSView {
    var histogram: HistogramData? { didSet { needsDisplay = true } }
    /// 0 RGB(밝기), 1 빨강, 2 초록, 3 파랑
    var channel = 0 { didSet { needsDisplay = true } }
    var values: [Float] = [0, 1, 1, 0, 1] { didSet { needsDisplay = true } }
    var onChange: (([Float], Bool) -> Void)?

    private enum Handle { case inBlack, mid, inWhite, outBlack, outWhite }
    private var grab: Handle?

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 150) }
    override var isFlipped: Bool { false }

    private var plot: NSRect { NSRect(x: 6, y: 58, width: bounds.width - 12, height: bounds.height - 62) }
    private var outBar: NSRect { NSRect(x: 6, y: 18, width: bounds.width - 12, height: 8) }
    private func x(_ v: Float, in r: NSRect) -> CGFloat { r.minX + r.width * CGFloat(min(max(v, 0), 1)) }
    private var midValue: Float { values[0] + (values[1] - values[0]) * pow(0.5, values[2]) }

    override func draw(_ dirtyRect: NSRect) {
        let p = plot
        NSColor.black.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: p, xRadius: 5, yRadius: 5).fill()
        // 4등분 눈금
        NSColor.white.withAlphaComponent(0.08).setStroke()
        for i in 1...3 {
            let gx = p.minX + p.width * CGFloat(i) / 4
            let l = NSBezierPath(); l.move(to: NSPoint(x: gx, y: p.minY)); l.line(to: NSPoint(x: gx, y: p.maxY))
            l.setLineDash([2, 3], count: 2, phase: 0); l.stroke()
        }
        if let d = histogram {
            let sets: [([Float], NSColor)] = switch channel {
            case 1: [(d.r, .systemRed)]
            case 2: [(d.g, .systemGreen)]
            case 3: [(d.b, .systemBlue)]
            default: [(d.r, .systemRed), (d.g, .systemGreen), (d.b, .systemBlue), (d.luma, .white)]
            }
            let top = max(sets.map { $0.0[1..<255].max() ?? 1 }.max() ?? 1, 1)
            NSGraphicsContext.current?.compositingOperation = .plusLighter
            for (bins, c) in sets {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: p.minX, y: p.minY))
                for (i, v) in bins.enumerated() {
                    path.line(to: NSPoint(x: p.minX + p.width * CGFloat(i) / 255, y: p.minY + p.height * CGFloat(min(sqrt(v / top), 1))))
                }
                path.line(to: NSPoint(x: p.maxX, y: p.minY)); path.close()
                c.withAlphaComponent(c == .white ? 0.22 : 0.45).setFill()
                path.fill()
            }
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        }
        // 입력 손잡이 (히스토그램 바로 아래)
        let hy = p.minY - 12
        triangle(x(values[0], in: p), hy, fill: NSColor(white: 0.1, alpha: 1))
        triangle(x(midValue, in: p), hy, fill: NSColor(white: 0.5, alpha: 1))
        triangle(x(values[1], in: p), hy, fill: .white)
        // 출력 막대와 손잡이
        let ob = outBar
        NSGradient(starting: .black, ending: .white)?.draw(in: NSBezierPath(roundedRect: ob, xRadius: 3, yRadius: 3), angle: 0)
        triangle(x(values[3], in: ob), ob.minY - 12, fill: NSColor(white: 0.1, alpha: 1))
        triangle(x(values[4], in: ob), ob.minY - 12, fill: .white)
    }

    /// 위를 가리키는 오각 손잡이
    private func triangle(_ cx: CGFloat, _ y: CGFloat, fill: NSColor) {
        let w: CGFloat = 12, h: CGFloat = 12
        let p = NSBezierPath()
        p.move(to: NSPoint(x: cx, y: y + h))
        p.line(to: NSPoint(x: cx + w / 2, y: y + h * 0.55))
        p.line(to: NSPoint(x: cx + w / 2, y: y))
        p.line(to: NSPoint(x: cx - w / 2, y: y))
        p.line(to: NSPoint(x: cx - w / 2, y: y + h * 0.55))
        p.close()
        fill.setFill(); p.fill()
        NSColor.white.withAlphaComponent(0.55).setStroke(); p.lineWidth = 0.8; p.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let q = convert(event.locationInWindow, from: nil)
        let p = plot, ob = outBar
        if q.y < ob.maxY + 4 {
            let cands: [(Handle, CGFloat)] = [(.outBlack, x(values[3], in: ob)), (.outWhite, x(values[4], in: ob))]
            grab = cands.min { abs($0.1 - q.x) < abs($1.1 - q.x) }?.0
        } else {
            let cands: [(Handle, CGFloat)] = [(.inBlack, x(values[0], in: p)), (.mid, x(midValue, in: p)), (.inWhite, x(values[1], in: p))]
            grab = cands.min { abs($0.1 - q.x) < abs($1.1 - q.x) }?.0
        }
        if event.clickCount == 2 {
            // 두 번 누르면 그 손잡이를 기본값으로
            switch grab {
            case .inBlack: values[0] = 0
            case .inWhite: values[1] = 1
            case .mid: values[2] = 1
            case .outBlack: values[3] = 0
            case .outWhite: values[4] = 1
            case nil: break
            }
            onChange?(values, false)
            grab = nil
        }
    }

    override func mouseDragged(with event: NSEvent) { drag(event, done: false) }
    override func mouseUp(with event: NSEvent) { drag(event, done: true); grab = nil }

    private func drag(_ event: NSEvent, done: Bool) {
        guard let grab else { return }
        let q = convert(event.locationInWindow, from: nil)
        let p = plot, ob = outBar
        func v(_ r: NSRect) -> Float { Float(min(max((q.x - r.minX) / r.width, 0), 1)) }
        switch grab {
        case .inBlack: values[0] = min(v(p), values[1] - 0.02)
        case .inWhite: values[1] = max(v(p), values[0] + 0.02)
        case .mid:
            let t = min(max((v(p) - values[0]) / max(values[1] - values[0], 0.001), 0.02), 0.98)
            values[2] = min(max(log(t) / log(0.5), 0.2), 3)
        case .outBlack: values[3] = min(v(ob), 0.9)
        case .outWhite: values[4] = max(v(ob), 0.1)
        }
        onChange?(values, !done)
    }
}
