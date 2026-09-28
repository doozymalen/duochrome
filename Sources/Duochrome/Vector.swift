import AppKit
import CoreImage

// MARK: - 벡터 패스: 펜 도구·모양 레이어·벡터 마스크·패스 패널이 함께 쓴다.
// 좌표는 모두 원본 픽셀(아래가 0)이라 사진과 같이 형태 보정을 따라간다.

/// 기준점 하나: 자리와 들어오는·나가는 조절점 (없으면 자리와 같음 = 모난 점)
struct PathAnchor: Equatable, Codable {
    var x: Double, y: Double
    var inX: Double, inY: Double
    var outX: Double, outY: Double

    init(_ p: CGPoint) { x = Double(p.x); y = Double(p.y); inX = x; inY = y; outX = x; outY = y }
    init(_ p: CGPoint, inH: CGPoint, outH: CGPoint) {
        x = Double(p.x); y = Double(p.y)
        inX = Double(inH.x); inY = Double(inH.y); outX = Double(outH.x); outY = Double(outH.y)
    }
    var point: CGPoint { get { CGPoint(x: x, y: y) } set { move(to: newValue) } }
    var inHandle: CGPoint { CGPoint(x: inX, y: inY) }
    var outHandle: CGPoint { CGPoint(x: outX, y: outY) }
    var isCorner: Bool { inX == x && inY == y && outX == x && outY == y }

    /// 조절점과 함께 옮긴다
    mutating func move(to p: CGPoint) {
        let dx = Double(p.x) - x, dy = Double(p.y) - y
        x += dx; y += dy; inX += dx; inY += dy; outX += dx; outY += dy
    }
    /// 매끄러운 점: 나가는 조절점을 정하면 들어오는 조절점은 반대쪽 같은 거리
    mutating func setSmooth(out o: CGPoint) {
        outX = Double(o.x); outY = Double(o.y)
        inX = 2 * x - outX; inY = 2 * y - outY
    }
    mutating func makeCorner() { inX = x; inY = y; outX = x; outY = y }
}

/// 패스 하나 (열린 선 또는 닫힌 모양)
struct VectorPath: Equatable, Codable {
    var id = UUID().uuidString
    var name = "패스"
    var anchors: [PathAnchor] = []
    var closed = false

    var isEmpty: Bool { anchors.count < 2 }

    /// 원본 좌표 × scale 의 CGPath
    func cgPath(scale k: CGFloat = 1) -> CGPath {
        let p = CGMutablePath()
        guard let first = anchors.first else { return p }
        func s(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x * k, y: q.y * k) }
        p.move(to: s(first.point))
        let n = anchors.count
        let segs = closed ? n : n - 1
        for i in 0..<max(segs, 0) {
            let a = anchors[i], b = anchors[(i + 1) % n]
            if a.outHandle == a.point && b.inHandle == b.point {
                p.addLine(to: s(b.point))
            } else {
                p.addCurve(to: s(b.point), control1: s(a.outHandle), control2: s(b.inHandle))
            }
        }
        if closed { p.closeSubpath() }
        return p
    }

    /// 짧은 선분으로 펼친 점들 (선택으로 바꾸기·패스 위 글자·획)
    func flattened(step: Double = 4) -> [CGPoint] {
        guard let first = anchors.first else { return [] }
        var out = [first.point]
        let n = anchors.count
        let segs = closed ? n : n - 1
        for i in 0..<max(segs, 0) {
            let a = anchors[i], b = anchors[(i + 1) % n]
            let p0 = a.point, p1 = a.outHandle, p2 = b.inHandle, p3 = b.point
            let approx = hypot(p1.x - p0.x, p1.y - p0.y) + hypot(p2.x - p1.x, p2.y - p1.y) + hypot(p3.x - p2.x, p3.y - p2.y)
            let m = max(1, Int(ceil(Double(approx) / step)))
            for j in 1...m {
                let t = CGFloat(j) / CGFloat(m), u = 1 - t
                let x = u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x
                let y = u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
                out.append(CGPoint(x: x, y: y))
            }
        }
        return out
    }

    var bounds: CGRect { cgPath().boundingBoxOfPath }

    /// 방향을 뒤집은 패스 (패스 위 글자를 반대쪽으로)
    var reversed: VectorPath {
        var r = self
        r.anchors = anchors.reversed().map { a in PathAnchor(a.point, inH: a.outHandle, outH: a.inHandle) }
        return r
    }

    // MARK: 모양 미리 만들기 (모양 도구)

    enum Preset: Int, CaseIterable {
        case rect, roundRect, ellipse, polygon, line, star, arrow
        var title: String { ["사각형", "둥근 사각형", "타원", "다각형", "선", "별", "화살표"][rawValue] }
    }

    /// 상자 안에 모양 (원본 좌표). sides: 다각형·별 꼭짓점 수, radius: 둥근 모서리, inner: 별 안쪽 비율, weight: 선 두께
    static func preset(_ kind: Preset, in r: CGRect, sides: Int = 6, radius: Double = 40, inner: Double = 0.45, weight: Double = 8) -> VectorPath {
        var v = VectorPath(name: kind.title)
        let k = 0.5523   // 원을 베지어 넷으로
        switch kind {
        case .rect:
            v.anchors = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map { PathAnchor($0) }
            v.closed = true
        case .roundRect:
            let c = min(CGFloat(radius), min(r.width, r.height) / 2), h = c * CGFloat(1 - k)
            v.anchors = [
                PathAnchor(CGPoint(x: r.minX + c, y: r.minY), inH: CGPoint(x: r.minX + h, y: r.minY), outH: CGPoint(x: r.minX + c, y: r.minY)),
                PathAnchor(CGPoint(x: r.maxX - c, y: r.minY), inH: CGPoint(x: r.maxX - c, y: r.minY), outH: CGPoint(x: r.maxX - h, y: r.minY)),
                PathAnchor(CGPoint(x: r.maxX, y: r.minY + c), inH: CGPoint(x: r.maxX, y: r.minY + h), outH: CGPoint(x: r.maxX, y: r.minY + c)),
                PathAnchor(CGPoint(x: r.maxX, y: r.maxY - c), inH: CGPoint(x: r.maxX, y: r.maxY - c), outH: CGPoint(x: r.maxX, y: r.maxY - h)),
                PathAnchor(CGPoint(x: r.maxX - c, y: r.maxY), inH: CGPoint(x: r.maxX - h, y: r.maxY), outH: CGPoint(x: r.maxX - c, y: r.maxY)),
                PathAnchor(CGPoint(x: r.minX + c, y: r.maxY), inH: CGPoint(x: r.minX + c, y: r.maxY), outH: CGPoint(x: r.minX + h, y: r.maxY)),
                PathAnchor(CGPoint(x: r.minX, y: r.maxY - c), inH: CGPoint(x: r.minX, y: r.maxY - h), outH: CGPoint(x: r.minX, y: r.maxY - c)),
                PathAnchor(CGPoint(x: r.minX, y: r.minY + c), inH: CGPoint(x: r.minX, y: r.minY + c), outH: CGPoint(x: r.minX, y: r.minY + h)),
            ]
            v.closed = true
        case .ellipse:
            let cx = r.midX, cy = r.midY, rx = r.width / 2, ry = r.height / 2, kx = rx * CGFloat(k), ky = ry * CGFloat(k)
            // 시계 방향 (왼쪽에서 시작해 위로): 패스 위 글자가 원 위쪽에서 바로 선다
            v.anchors = [
                PathAnchor(CGPoint(x: cx - rx, y: cy), inH: CGPoint(x: cx - rx, y: cy - ky), outH: CGPoint(x: cx - rx, y: cy + ky)),
                PathAnchor(CGPoint(x: cx, y: cy + ry), inH: CGPoint(x: cx - kx, y: cy + ry), outH: CGPoint(x: cx + kx, y: cy + ry)),
                PathAnchor(CGPoint(x: cx + rx, y: cy), inH: CGPoint(x: cx + rx, y: cy + ky), outH: CGPoint(x: cx + rx, y: cy - ky)),
                PathAnchor(CGPoint(x: cx, y: cy - ry), inH: CGPoint(x: cx + kx, y: cy - ry), outH: CGPoint(x: cx - kx, y: cy - ry)),
            ]
            v.closed = true
        case .polygon, .star:
            let n = max(3, sides), cx = r.midX, cy = r.midY, rx = r.width / 2, ry = r.height / 2
            let count = kind == .star ? n * 2 : n
            v.anchors = (0..<count).map { i in
                let a = CGFloat.pi / 2 + CGFloat(i) * 2 * .pi / CGFloat(count)
                let f: CGFloat = kind == .star && i % 2 == 1 ? CGFloat(inner) : 1
                return PathAnchor(CGPoint(x: cx + cos(a) * rx * f, y: cy + sin(a) * ry * f))
            }
            v.closed = true
        case .line:
            // 두께 있는 선: 시작(왼아래)→끝(오른위) 방향의 얇은 사각형
            let a = CGPoint(x: r.minX, y: r.minY), b = CGPoint(x: r.maxX, y: r.maxY)
            let len = max(hypot(b.x - a.x, b.y - a.y), 1), w = CGFloat(weight) / 2
            let nx = -(b.y - a.y) / len * w, ny = (b.x - a.x) / len * w
            v.anchors = [CGPoint(x: a.x + nx, y: a.y + ny), CGPoint(x: b.x + nx, y: b.y + ny), CGPoint(x: b.x - nx, y: b.y - ny), CGPoint(x: a.x - nx, y: a.y - ny)].map { PathAnchor($0) }
            v.closed = true
        case .arrow:
            let h = r.height, shaft = h * 0.35, head = r.width * 0.35
            let y0 = r.midY - shaft / 2, y1 = r.midY + shaft / 2
            v.anchors = [CGPoint(x: r.minX, y: y0), CGPoint(x: r.maxX - head, y: y0), CGPoint(x: r.maxX - head, y: r.minY),
                         CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX - head, y: r.maxY), CGPoint(x: r.maxX - head, y: y1),
                         CGPoint(x: r.minX, y: y1)].map { PathAnchor($0) }
            v.closed = true
        }
        return v
    }

    /// 곡률 펜: 누른 점들을 지나는 매끄러운 곡선 (캣멀롬 → 베지어)
    static func curvature(_ pts: [CGPoint], closed: Bool) -> [PathAnchor] {
        let n = pts.count
        guard n >= 3 else { return pts.map { PathAnchor($0) } }
        return (0..<n).map { i in
            let p = pts[i]
            let prev = closed ? pts[(i - 1 + n) % n] : pts[max(i - 1, 0)]
            let next = closed ? pts[(i + 1) % n] : pts[min(i + 1, n - 1)]
            if !closed && (i == 0 || i == n - 1) { return PathAnchor(p) }
            let tx = (next.x - prev.x) / 6, ty = (next.y - prev.y) / 6
            return PathAnchor(p, inH: CGPoint(x: p.x - tx, y: p.y - ty), outH: CGPoint(x: p.x + tx, y: p.y + ty))
        }
    }

    /// 자유 펜: 끌어 그린 점들을 줄여(더글러스-포이커) 매끄러운 기준점으로
    static func freeform(_ pts: [CGPoint], tolerance: CGFloat) -> [PathAnchor] {
        guard pts.count > 2 else { return pts.map { PathAnchor($0) } }
        func simplify(_ a: Int, _ b: Int, _ keep: inout [Bool]) {
            guard b > a + 1 else { return }
            let p = pts[a], q = pts[b]
            let len = max(hypot(q.x - p.x, q.y - p.y), 1e-6)
            var best = 0 as CGFloat, idx = a
            for i in (a + 1)..<b {
                let d = abs((q.y - p.y) * pts[i].x - (q.x - p.x) * pts[i].y + q.x * p.y - q.y * p.x) / len
                if d > best { best = d; idx = i }
            }
            if best > tolerance { keep[idx] = true; simplify(a, idx, &keep); simplify(idx, b, &keep) }
        }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true; keep[pts.count - 1] = true
        simplify(0, pts.count - 1, &keep)
        let chosen = pts.enumerated().filter { keep[$0.offset] }.map(\.element)
        return curvature(chosen, closed: false)
    }
}

/// 모양 레이어 (kind "shape"): 패스 + 채우기 + 획
struct VectorShape: Equatable, Codable {
    var path: VectorPath
    /// 채우기 색 (화면 값 RGB, nil이면 채우지 않음)
    var fill: [Float]? = [0.9, 0.9, 0.9]
    /// 획 색 (nil이면 획 없음)
    var stroke: [Float]? = nil
    /// 획 두께 (원본 픽셀)
    var strokeWidth: Double = 6
    /// 획 자리: 0 가운데, 1 안쪽, 2 바깥쪽
    var strokeAlign: Int = 0
    /// 점선: [선, 빈칸] (원본 픽셀), 비면 실선
    var dash: [Double] = []
}

enum VectorRender {
    private static var cache: [String: CIImage] = [:]
    private static let lock = NSLock()

    private static func key(_ tag: String, _ v: Any, _ scale: CGFloat, _ rect: CGRect) -> String {
        "\(tag)|\(v)|\(scale)|\(rect)".hashValue.description
    }

    /// 모양 레이어를 원본 좌표 × scale 그림으로 (투명 바탕)
    static func shapeImage(_ s: VectorShape, scale k: CGFloat, nativeRect: CGRect) -> CIImage {
        let cacheKey = key("s", s, k, nativeRect)
        lock.lock(); if let hit = cache[cacheKey] { lock.unlock(); return hit }; lock.unlock()
        let path = s.path.cgPath(scale: k)
        let sw = CGFloat(s.strokeWidth) * k
        let pad = s.stroke != nil ? sw + 2 : 2
        let bb = path.boundingBoxOfPath.insetBy(dx: -pad, dy: -pad).intersection(nativeRect).integral
        guard bb.width >= 1, bb.height >= 1, bb.width < 32000, bb.height < 32000,
              let ctx = CGContext(data: nil, width: Int(bb.width), height: Int(bb.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return CIImage.empty() }
        ctx.translateBy(x: -bb.minX, y: -bb.minY)
        ctx.setShouldAntialias(true)
        func color(_ c: [Float]) -> CGColor {
            let v = c + [1, 1, 1]
            return CGColor(srgbRed: CGFloat(v[0]), green: CGFloat(v[1]), blue: CGFloat(v[2]), alpha: 1)
        }
        if let f = s.fill, s.path.closed {
            ctx.addPath(path); ctx.setFillColor(color(f)); ctx.fillPath()
        }
        if let st = s.stroke {
            ctx.saveGState()
            ctx.setStrokeColor(color(st))
            if !s.dash.isEmpty { ctx.setLineDash(phase: 0, lengths: s.dash.map { CGFloat($0) * k }) }
            ctx.setLineJoin(.round); ctx.setLineCap(.round)
            switch s.strokeAlign {
            case 1 where s.path.closed:   // 안쪽: 모양으로 자르고 두 배 두께
                ctx.addPath(path); ctx.clip(); ctx.setLineWidth(sw * 2); ctx.addPath(path); ctx.strokePath()
            case 2 where s.path.closed:   // 바깥쪽: 모양 밖만 남긴다
                ctx.addRect(bb); ctx.addPath(path); ctx.clip(using: .evenOdd)
                ctx.setLineWidth(sw * 2); ctx.addPath(path); ctx.strokePath()
            default:
                ctx.setLineWidth(sw); ctx.addPath(path); ctx.strokePath()
            }
            ctx.restoreGState()
        }
        guard let cg = ctx.makeImage() else { return CIImage.empty() }
        let img = CIImage(cgImage: cg).transformed(by: .init(translationX: bb.minX, y: bb.minY))
        lock.lock(); if cache.count > 48 { cache.removeAll() }; cache[cacheKey] = img; lock.unlock()
        return img
    }

    /// 벡터 마스크: 패스 안이 흰색 (원본 좌표 × scale, nativeRect 전체)
    static func mask(_ v: VectorPath, scale k: CGFloat, nativeRect: CGRect) -> CIImage {
        let cacheKey = key("m", v, k, nativeRect)
        lock.lock(); if let hit = cache[cacheKey] { lock.unlock(); return hit }; lock.unlock()
        // 마스크는 원본 크기가 크므로 긴 변 4096 이하로 그려 늘린다
        let down = min(1, 4096 / max(nativeRect.width, nativeRect.height))
        let w = Int(ceil(nativeRect.width * down)), h = Int(ceil(nativeRect.height * down))
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return CIImage(color: .white).cropped(to: nativeRect) }
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setShouldAntialias(true)
        ctx.translateBy(x: -nativeRect.minX * down, y: -nativeRect.minY * down)
        ctx.addPath(v.cgPath(scale: k * down))
        ctx.setFillColor(gray: 1, alpha: 1)
        if v.closed || v.anchors.count > 2 { ctx.fillPath() }
        guard let cg = ctx.makeImage() else { return CIImage(color: .white).cropped(to: nativeRect) }
        var img = CIImage(cgImage: cg)
        if down < 1 { img = img.transformed(by: .init(scaleX: 1 / down, y: 1 / down)) }
        img = img.transformed(by: .init(translationX: nativeRect.minX, y: nativeRect.minY)).cropped(to: nativeRect)
        lock.lock(); if cache.count > 48 { cache.removeAll() }; cache[cacheKey] = img; lock.unlock()
        return img
    }
}

extension Layers {
    /// 모양 레이어: 원본 좌표에 그리고 사진과 같은 형태 보정을 거친다
    static func placedShape(_ s: VectorShape, scale: CGFloat, native: CGSize, shape: (CIImage, CGFloat) -> CIImage, frame: CGRect) -> CIImage? {
        let nativeRect = CGRect(x: 0, y: 0, width: native.width * scale, height: native.height * scale).integral
        let img = VectorRender.shapeImage(s, scale: scale, nativeRect: nativeRect)
        let canvas = img.cropped(to: nativeRect).composited(over: CIImage(color: .clear).cropped(to: nativeRect))
        return shape(canvas, scale).cropped(to: frame)
    }
}

// MARK: - 캔버스 위 패스 편집 층 (펜·자유 펜·곡률 펜·직접 선택·모양 끌기·글자 상자)

final class PathOverlayView: NSView {
    enum Mode { case pen, freePen, curvature, direct, shapeDrag, textBox }
    var mode: Mode = .pen { didSet { needsDisplay = true; curvaturePoints = [] } }
    /// 지금 편집하는 패스 (원본 좌표)
    var path = VectorPath() { didSet { needsDisplay = true } }
    /// 다른 패스 (흐리게, 참고용)
    var others: [VectorPath] = [] { didSet { needsDisplay = true } }
    var toView: ((CGPoint) -> CGPoint)?
    var fromView: ((CGPoint) -> CGPoint)?
    /// 패스가 바뀜 (끄는 중인지)
    var onChange: ((VectorPath, Bool) -> Void)?
    /// 모양·글자 상자를 끌어 정함 (원본 좌표 상자, 그냥 누르기면 너비·높이 0)
    var onBox: ((CGRect) -> Void)?
    /// 엔터·닫기: 패스를 끝냄
    var onFinish: (() -> Void)?

    private var drag: (kind: Int, index: Int)?   // 0 기준점, 1 들어오는 조절점, 2 나가는 조절점
    private var freePoints: [CGPoint] = []
    private var curvaturePoints: [CGPoint] = []
    private var boxStart: CGPoint?
    private var boxNow: CGPoint?
    private var mouse: CGPoint?
    private var newAnchor: Int?

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : super.hitTest(point) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        if mode == .pen || mode == .curvature { needsDisplay = true }
    }

    private func v(_ p: CGPoint) -> CGPoint { toView?(p) ?? p }
    private func n(_ p: CGPoint) -> CGPoint { fromView?(p) ?? p }

    /// 원본 좌표 패스를 뷰 좌표 NSBezierPath로
    private func bezier(_ path: VectorPath) -> NSBezierPath {
        let b = NSBezierPath()
        guard let first = path.anchors.first else { return b }
        b.move(to: v(first.point))
        let c = path.anchors.count
        for i in 0..<(path.closed ? c : c - 1) {
            let a = path.anchors[i], z = path.anchors[(i + 1) % c]
            b.curve(to: v(z.point), controlPoint1: v(a.outHandle), controlPoint2: v(z.inHandle))
        }
        if path.closed { b.close() }
        return b
    }

    override func draw(_ dirtyRect: NSRect) {
        for o in others {
            let b = bezier(o); b.lineWidth = 1
            NSColor.white.withAlphaComponent(0.35).setStroke(); b.stroke()
        }
        // 편집 중인 패스
        let b = bezier(path)
        b.lineWidth = 1.5
        NSColor.black.withAlphaComponent(0.5).setStroke(); b.stroke()
        b.lineWidth = 1
        NSColor.controlAccentColor.setStroke(); b.stroke()
        // 다음 점 미리 보기 (펜)
        if mode == .pen, !path.closed, let last = path.anchors.last, let m = mouse, drag == nil {
            let r = NSBezierPath(); r.move(to: v(last.point))
            r.curve(to: m, controlPoint1: v(last.outHandle), controlPoint2: m)
            r.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke(); r.stroke()
        }
        if mode == .curvature, !curvaturePoints.isEmpty {
            for p in curvaturePoints { dot(v(p), 4, filled: true) }
        }
        if mode == .freePen, freePoints.count > 1 {
            let f = NSBezierPath(); f.move(to: v(freePoints[0])); freePoints.dropFirst().forEach { f.line(to: v($0)) }
            NSColor.controlAccentColor.setStroke(); f.lineWidth = 1.5; f.stroke()
        }
        if let s = boxStart, let e = boxNow {
            let r = NSRect(x: min(v(s).x, v(e).x), y: min(v(s).y, v(e).y), width: abs(v(e).x - v(s).x), height: abs(v(e).y - v(s).y))
            let box = NSBezierPath(rect: r); box.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.white.setStroke(); box.stroke()
        }
        // 기준점과 조절점
        for (i, a) in path.anchors.enumerated() {
            if !a.isCorner {
                for h in [a.inHandle, a.outHandle] where h != a.point {
                    let l = NSBezierPath(); l.move(to: v(a.point)); l.line(to: v(h))
                    NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke(); l.lineWidth = 1; l.stroke()
                    dot(v(h), 3.5, filled: true)
                }
            }
            let p = v(a.point)
            let sq = NSRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            (i == 0 && !path.closed ? NSColor.controlAccentColor : NSColor.white).setFill(); sq.fill()
            NSColor.black.withAlphaComponent(0.7).setStroke(); NSBezierPath(rect: sq).stroke()
        }
    }

    private func dot(_ p: CGPoint, _ r: CGFloat, filled: Bool) {
        let o = NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        NSColor.white.setFill(); if filled { o.fill() }
        NSColor.controlAccentColor.setStroke(); o.stroke()
    }

    /// 뷰 점에서 가까운 기준점·조절점
    private func hit(_ p: CGPoint) -> (kind: Int, index: Int)? {
        for (i, a) in path.anchors.enumerated().reversed() {
            if hypot(v(a.outHandle).x - p.x, v(a.outHandle).y - p.y) < 6, !a.isCorner { return (2, i) }
            if hypot(v(a.inHandle).x - p.x, v(a.inHandle).y - p.y) < 6, !a.isCorner { return (1, i) }
            if hypot(v(a.point).x - p.x, v(a.point).y - p.y) < 7 { return (0, i) }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let np = n(p)
        newAnchor = nil
        switch mode {
        case .shapeDrag, .textBox:
            boxStart = np; boxNow = np
        case .freePen:
            freePoints = [np]
        case .curvature:
            if let h = hit(p), h.kind == 0 {
                drag = h
                if h.index == 0, curvaturePoints.count >= 3 { closeCurvature(); return }
                return
            }
            curvaturePoints.append(np)
            path.anchors = VectorPath.curvature(curvaturePoints, closed: false)
            path.closed = false
            onChange?(path, false)
        case .direct:
            drag = hit(p)
            if let d = drag, event.modifierFlags.contains(.option), d.kind == 0 {
                // ⌥누르기: 모난 점 ↔ 매끄러운 점
                if path.anchors[d.index].isCorner {
                    let a = path.anchors[d.index]
                    let prev = path.anchors[(d.index - 1 + path.anchors.count) % path.anchors.count].point
                    let next = path.anchors[(d.index + 1) % path.anchors.count].point
                    let tx = (next.x - prev.x) / 6, ty = (next.y - prev.y) / 6
                    path.anchors[d.index].setSmooth(out: CGPoint(x: a.x + Double(tx), y: a.y + Double(ty)))
                } else {
                    path.anchors[d.index].makeCorner()
                }
                drag = nil
                onChange?(path, false)
            }
        case .pen:
            if path.closed { path = VectorPath(name: path.name) }
            if let h = hit(p), h.kind == 0 {
                if h.index == 0, path.anchors.count >= 2 {
                    path.closed = true
                    onChange?(path, false)
                    onFinish?()
                    return
                }
                if event.modifierFlags.contains(.option) || h.index == path.anchors.count - 1 {
                    // 마지막 점 ⌥누르기: 나가는 조절점 없애기 (모난 점으로 이어 가기)
                    path.anchors[h.index].outX = path.anchors[h.index].x
                    path.anchors[h.index].outY = path.anchors[h.index].y
                    onChange?(path, false)
                    return
                }
                drag = h
                return
            }
            path.anchors.append(PathAnchor(np))
            newAnchor = path.anchors.count - 1
            onChange?(path, true)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let np = n(p)
        switch mode {
        case .shapeDrag, .textBox:
            var e = np
            if event.modifierFlags.contains(.shift), let s = boxStart {
                // ⇧: 정사각·정원
                let d = max(abs(e.x - s.x), abs(e.y - s.y))
                e = CGPoint(x: s.x + (e.x >= s.x ? d : -d), y: s.y + (e.y >= s.y ? d : -d))
            }
            boxNow = e; needsDisplay = true
        case .freePen:
            freePoints.append(np); needsDisplay = true
        case .pen where newAnchor != nil:
            // 새 점을 누른 채 끌면 매끄러운 점 (조절점을 끌어낸다)
            path.anchors[newAnchor!].setSmooth(out: np)
            onChange?(path, true)
        default:
            guard let d = drag, path.anchors.indices.contains(d.index) else { return }
            switch d.kind {
            case 0: path.anchors[d.index].move(to: np)
            case 1:
                path.anchors[d.index].inX = Double(np.x); path.anchors[d.index].inY = Double(np.y)
                if !event.modifierFlags.contains(.option) {   // 반대쪽도 같이 (⌥이면 따로)
                    let a = path.anchors[d.index]
                    path.anchors[d.index].outX = 2 * a.x - a.inX; path.anchors[d.index].outY = 2 * a.y - a.inY
                }
            default:
                if event.modifierFlags.contains(.option) {
                    path.anchors[d.index].outX = Double(np.x); path.anchors[d.index].outY = Double(np.y)
                } else {
                    path.anchors[d.index].setSmooth(out: np)
                }
            }
            if mode == .curvature, d.kind == 0, curvaturePoints.indices.contains(d.index) {
                curvaturePoints[d.index] = np
                path.anchors = VectorPath.curvature(curvaturePoints, closed: path.closed)
            }
            onChange?(path, true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .shapeDrag, .textBox:
            if let s = boxStart, let e = boxNow {
                onBox?(CGRect(x: min(s.x, e.x), y: min(s.y, e.y), width: abs(e.x - s.x), height: abs(e.y - s.y)))
            }
            boxStart = nil; boxNow = nil
        case .freePen:
            if freePoints.count > 2 {
                // 허용 오차는 화면 3픽셀
                let tol = abs(n(CGPoint(x: 3, y: 0)).x - n(.zero).x)
                path = VectorPath(name: path.name, anchors: VectorPath.freeform(freePoints, tolerance: max(tol, 0.5)), closed: false)
                onFinish?()
            }
            freePoints = []
        default: break
        }
        drag = nil
        newAnchor = nil
        onChange?(path, false)
        needsDisplay = true
    }

    private func closeCurvature() {
        path.anchors = VectorPath.curvature(curvaturePoints, closed: true)
        path.closed = true
        curvaturePoints = []
        onChange?(path, false)
        onFinish?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:   // 엔터: 끝내기
            curvaturePoints = []
            onFinish?()
        case 53:       // esc
            curvaturePoints = []
            onFinish?()
        case 51, 117:  // ⌫: 마지막 점 지우기 (펜·곡률 펜)
            if mode == .curvature, !curvaturePoints.isEmpty {
                curvaturePoints.removeLast()
                path.anchors = VectorPath.curvature(curvaturePoints, closed: false)
            } else if !path.anchors.isEmpty {
                path.anchors.removeLast(); path.closed = false
            }
            onChange?(path, false)
        default: super.keyDown(with: event)
        }
    }
}
