import AppKit
import CoreImage

/// 화면에 보이는 값(Display P3) 기준 256칸 히스토그램.
struct HistogramData {
    var r = [Float](repeating: 0, count: 256)
    var g = [Float](repeating: 0, count: 256)
    var b = [Float](repeating: 0, count: 256)
    var luma = [Float](repeating: 0, count: 256)
    /// 한 채널이라도 끝까지 간 픽셀의 비율.
    var clippedHigh: Float = 0
    var clippedLow: Float = 0

    /// 미리보기 단계 이미지를 가로 512픽셀 이하로 줄여 센다. 모양을 보는 데는 충분하다.
    static func compute(_ image: CIImage, context: CIContext, space: CGColorSpace) -> HistogramData {
        var img = image
        let longSide = max(img.extent.width, img.extent.height)
        if longSide > 512 {
            let k = 512 / longSide
            img = img.transformed(by: .init(scaleX: k, y: k))
        }
        let w = Int(img.extent.width.rounded(.down)), h = Int(img.extent.height.rounded(.down))
        guard w > 0, h > 0 else { return HistogramData() }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        context.render(img, toBitmap: &px, rowBytes: w * 4,
                       bounds: CGRect(x: img.extent.minX, y: img.extent.minY, width: CGFloat(w), height: CGFloat(h)),
                       format: .RGBA8, colorSpace: space)

        var d = HistogramData()
        var hi = 0, lo = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            d.r[r] += 1; d.g[g] += 1; d.b[b] += 1
            d.luma[(r * 54 + g * 183 + b * 19) >> 8] += 1
            if max(r, g, b) >= 255 { hi += 1 }
            if max(r, g, b) <= 0 { lo += 1 }
        }
        let n = Float(w * h)
        d.clippedHigh = Float(hi) / n
        d.clippedLow = Float(lo) / n
        return d
    }
}

final class HistogramView: NSView {
    var data: HistogramData? { didSet { needsDisplay = true; mirror?.histogram = data } }
    /// 같은 히스토그램을 보여 줄 레벨 조절 (조정 탭 레벨 카드)
    weak var mirror: LevelsView?

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 96) }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds
        NSColor.black.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        guard let d = data else { return }

        // 끝 칸(순수 검정·흰색)은 제외하고 높이를 잡는다. 안 그러면 밤 사진이 한 줄로 눌린다.
        let peak = [d.r, d.g, d.b, d.luma].map { $0[1..<255].max() ?? 1 }.max() ?? 1
        let top = max(peak, 1)
        let plot = box.insetBy(dx: 4, dy: 4)

        func path(_ bins: [Float]) -> NSBezierPath {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: plot.minX, y: plot.minY))
            for (i, v) in bins.enumerated() {
                let x = plot.minX + plot.width * CGFloat(i) / 255
                // 제곱근 눈금: 작은 봉우리도 보이게.
                let y = plot.minY + plot.height * CGFloat(min(sqrt(v / top), 1))
                p.line(to: NSPoint(x: x, y: y))
            }
            p.line(to: NSPoint(x: plot.maxX, y: plot.minY))
            p.close()
            return p
        }

        NSGraphicsContext.current?.compositingOperation = .plusLighter
        NSColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 0.55).setFill(); path(d.r).fill()
        NSColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 0.55).setFill(); path(d.g).fill()
        NSColor(red: 0.25, green: 0.4, blue: 1.0, alpha: 0.55).setFill(); path(d.b).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        NSColor.white.withAlphaComponent(0.7).setStroke()
        let l = path(d.luma); l.lineWidth = 1; l.stroke()

        // 클리핑 표시: 0.1%를 넘으면 모서리 삼각형에 불이 들어온다.
        func corner(_ left: Bool, lit: Bool, color: NSColor) {
            let s: CGFloat = 8
            let x = left ? box.minX + 5 : box.maxX - 5
            let t = NSBezierPath()
            t.move(to: NSPoint(x: x, y: box.maxY - 5))
            t.line(to: NSPoint(x: x + (left ? s : -s), y: box.maxY - 5))
            t.line(to: NSPoint(x: x, y: box.maxY - 5 - s))
            t.close()
            (lit ? color : NSColor.white.withAlphaComponent(0.15)).setFill()
            t.fill()
        }
        corner(true, lit: d.clippedLow > 0.001, color: NSColor(red: 0.3, green: 0.55, blue: 1, alpha: 1))
        corner(false, lit: d.clippedHigh > 0.001, color: NSColor(red: 1, green: 0.3, blue: 0.3, alpha: 1))
    }
}
