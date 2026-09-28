import CoreImage

/// 크롭 영역. 형태 보정을 마친 틀 기준 0~1 좌표 (아래가 0).
struct CropRect: Equatable, Codable {
    var x: Double = 0, y: Double = 0, w: Double = 1, h: Double = 1
    var isFull: Bool { x == 0 && y == 0 && w == 1 && h == 1 }
    var cg: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    init() {}
    init(_ r: CGRect) { x = r.minX; y = r.minY; w = r.width; h = r.height }
}

/// "형태" 탭의 계산: 90° 회전·뒤집기 → 미세 회전 → 키스톤 → 크롭.
///
/// 회전과 키스톤은 틀(frame) 크기를 바꾸지 않는다. 빈 모서리가 생기지 않도록 사진을 키워서
/// 틀을 덮는다. 크기가 바뀌는 건 90° 회전과 크롭뿐이다.
enum Geometry {
    /// 90° 회전을 반영한 틀 크기 (원본 픽셀).
    static func frameSize(_ s: DevelopSettings, native: CGSize) -> CGSize {
        if let q = perspectiveQuad(s) { return perspectiveSize(q) }
        return turnSize(s, native: native)
    }

    /// 90° 회전만 반영한 틀 (원근 자르기 전)
    static func turnSize(_ s: DevelopSettings, native: CGSize) -> CGSize {
        Int(s.quarterTurns) % 2 == 0 ? native : CGSize(width: native.height, height: native.width)
    }

    /// 크롭까지 반영한 결과 크기 (원본 픽셀). 캔버스 여백을 더한다.
    static func croppedSize(_ s: DevelopSettings, native: CGSize) -> CGSize {
        let f = frameSize(s, native: native)
        let w = (f.width * s.crop.w).rounded(), h = (f.height * s.crop.h).rounded()
        guard let p = s.canvasPad, p.count == 4 else { return CGSize(width: w, height: h) }
        return CGSize(width: (w * (1 + p[0] + p[2])).rounded(), height: (h * (1 + p[1] + p[3])).rounded())
    }

    static func isIdentity(_ s: DevelopSettings) -> Bool {
        s.quarterTurns == 0 && s.flipH == 0 && s.flipV == 0 && s.rotation == 0
            && s.keystoneV == 0 && s.keystoneH == 0 && s.keystoneAspect == 0 && s.perspective == nil
    }

    // MARK: - 원근 자르기

    static func perspectiveQuad(_ s: DevelopSettings) -> [CGPoint]? {
        guard let q = s.perspective, q.count == 8 else { return nil }
        return (0 ..< 4).map { CGPoint(x: q[$0 * 2], y: q[$0 * 2 + 1]) }
    }

    /// 네 점 → 반듯한 사각형 크기 (마주 보는 변 길이의 평균)
    static let homographyK = try? CIKernel(source: """
        kernel vec4 k(sampler s, vec3 r0, vec3 r1, vec3 r2) {
            vec3 p = vec3(destCoord(), 1.0);
            float w = dot(r2, p);
            vec2 q = vec2(dot(r0, p), dot(r1, p)) / w;
            return sample(s, samplerTransform(s, q));
        }
        """)

    /// 그림을 호모그래피 H(원래 → 결과, scale 1 좌표)로 옮긴다. 결과 영역 out은 scale 좌표.
    static func homographyWarp(_ img: CIImage, _ h: Homography, scale: CGFloat, out: CGRect) -> CIImage {
        let inv = h.inverse.m
        // scale 좌표: q = S · H⁻¹ · S⁻¹ · p
        let k = Double(scale)
        let m = [inv[0], inv[1], inv[2] * k, inv[3], inv[4], inv[5] * k, inv[6] / k, inv[7] / k, inv[8]]
        guard let kern = homographyK else { return img }
        let e = img.extent
        return kern.apply(extent: out, roiCallback: { _, _ in e }, arguments: [
            img, CIVector(x: m[0], y: m[1], z: m[2]), CIVector(x: m[3], y: m[4], z: m[5]), CIVector(x: m[6], y: m[7], z: m[8]),
        ]) ?? img
    }

    static func perspectiveSize(_ q: [CGPoint]) -> CGSize {
        func d(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        return CGSize(width: ((d(q[0], q[1]) + d(q[3], q[2])) / 2).rounded(), height: ((d(q[0], q[3]) + d(q[1], q[2])) / 2).rounded())
    }

    /// 틀 좌표 → 원근 자르기 결과 좌표 (scale 1)
    static func perspectiveHomography(_ q: [CGPoint]) -> Homography {
        let sz = perspectiveSize(q)
        return Homography(from: q, to: [CGPoint(x: 0, y: 0), CGPoint(x: sz.width, y: 0), CGPoint(x: sz.width, y: sz.height), CGPoint(x: 0, y: sz.height)])
    }

    // MARK: - 단계별 변환 (그리기와 좌표 변환이 같은 계산을 쓰게 한 곳에 둔다)

    /// 90° 회전·뒤집기: 디코딩 이미지(w×h) → 틀. 틀 크기도 돌려준다.
    static func turnTransform(_ s: DevelopSettings, w: CGFloat, h: CGFloat) -> (CGAffineTransform, CGSize) {
        let turns = Int(s.quarterTurns) % 4
        var t = CGAffineTransform(translationX: -w / 2, y: -h / 2)
        if s.flipH != 0 { t = t.concatenating(.init(scaleX: -1, y: 1)) }
        if s.flipV != 0 { t = t.concatenating(.init(scaleX: 1, y: -1)) }
        // Core Image 좌표는 위가 +y라 양의 각도가 반시계 방향이다. 한 번 = 시계 방향 90°.
        t = t.concatenating(.init(rotationAngle: -CGFloat(turns) * .pi / 2))
        let size = turns % 2 == 1 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        t = t.concatenating(.init(translationX: size.width / 2, y: size.height / 2))
        return (t, size)
    }

    /// 미세 회전: 돌린 사진이 틀을 다 덮는 최소 배율로 키운다.
    static func rotationTransform(_ rotation: Float, w: CGFloat, h: CGFloat) -> CGAffineTransform {
        let a = CGFloat(abs(rotation)) * .pi / 180
        let k = max((w * cos(a) + h * sin(a)) / w, (w * sin(a) + h * cos(a)) / h)
        return CGAffineTransform(translationX: -w / 2, y: -h / 2)
            .concatenating(.init(rotationAngle: CGFloat(-rotation) * .pi / 180))
            .concatenating(.init(scaleX: k, y: k))
            .concatenating(.init(translationX: w / 2, y: h / 2))
    }

    static func hasKeystone(_ s: DevelopSettings) -> Bool {
        s.keystoneV != 0 || s.keystoneH != 0 || s.keystoneAspect != 0
    }

    /// 키스톤이 틀의 네 모서리를 옮길 자리: 왼위, 오른위, 왼아래, 오른아래.
    /// 세로가 양수면 위쪽을 넓혀 위로 모이는 세로선을 편다. 가로는 오른쪽을 넓힌다.
    /// 모서리를 바깥으로만 밀기 때문에 결과가 틀을 늘 덮는다.
    static func keystoneQuad(v kv: Float, h kh: Float, aspect: Float, w: CGFloat, h: CGFloat) -> [CGPoint] {
        let v = CGFloat(kv) / 100 * 0.35, hk = CGFloat(kh) / 100 * 0.35
        let dxTop = max(v, 0) * w / 2, dxBottom = max(-v, 0) * w / 2
        let dyRight = max(hk, 0) * h / 2, dyLeft = max(-hk, 0) * h / 2
        // 비율: 키스톤으로 눌린 세로를 되살린다 (양수면 세로로 늘인다).
        let stretch = 1 + CGFloat(aspect) / 100 * 0.3
        let cy = h / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: cy + (y - cy) * stretch) }
        return [p(-dxTop, h + dyLeft), p(w + dxTop, h + dyRight), p(-dxBottom, -dyLeft), p(w + dxBottom, -dyRight)]
    }

    static func keystoneHomography(v: Float, h kh: Float, aspect: Float, w: CGFloat, h: CGFloat) -> Homography {
        Homography(from: [CGPoint(x: 0, y: h), CGPoint(x: w, y: h), CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0)],
                   to: keystoneQuad(v: v, h: kh, aspect: aspect, w: w, h: h))
    }

    /// 크롭 전까지. 결과 영역은 (0, 0, 틀 × scale).
    static func transform(_ s: DevelopSettings, _ image: CIImage, scale: CGFloat) -> CIImage {
        guard !isIdentity(s) else { return image }
        var img = image
        let (turn, size) = turnTransform(s, w: img.extent.width, h: img.extent.height)
        let w = size.width, h = size.height
        if s.quarterTurns != 0 || s.flipH != 0 || s.flipV != 0 { img = img.transformed(by: turn) }
        let frame = CGRect(x: 0, y: 0, width: w, height: h)

        if s.rotation != 0 {
            img = img.clampedToExtent().transformed(by: rotationTransform(s.rotation, w: w, h: h)).cropped(to: frame)
        }
        if hasKeystone(s) {
            let q = keystoneQuad(v: s.keystoneV, h: s.keystoneH, aspect: s.keystoneAspect, w: w, h: h)
            img = img.clampedToExtent().cropped(to: frame).applyingFilter("CIPerspectiveTransform", parameters: [
                "inputTopLeft": CIVector(cgPoint: q[0]), "inputTopRight": CIVector(cgPoint: q[1]),
                "inputBottomLeft": CIVector(cgPoint: q[2]), "inputBottomRight": CIVector(cgPoint: q[3]),
            ]).cropped(to: frame)
        }
        if let q = perspectiveQuad(s) {
            let hm = perspectiveHomography(q)
            let sz = perspectiveSize(q)
            let out = CGRect(x: 0, y: 0, width: (sz.width * scale).rounded(), height: (sz.height * scale).rounded())
            // 결과 좌표 → 틀 좌표 (역변환)로 읽는다. CIPerspectiveTransform은 일부 영역만 그리면 비는 일이 있었다.
            img = homographyWarp(img.clampedToExtent().cropped(to: frame), hm, scale: scale, out: out)
        }
        return img
    }

    static func crop(_ s: DevelopSettings, _ image: CIImage) -> CIImage {
        var out = image
        if !s.crop.isFull {
            let e = image.extent
            let r = CGRect(x: e.minX + e.width * s.crop.x, y: e.minY + e.height * s.crop.y,
                           width: e.width * s.crop.w, height: e.height * s.crop.h).integral
            out = image.cropped(to: r).transformed(by: .init(translationX: -r.minX, y: -r.minY))
        }
        // 캔버스 여백
        if let p = s.canvasPad, p.count == 4 {
            let e = out.extent
            let l = (e.width * p[0]).rounded(), b = (e.height * p[1]).rounded()
            let full = CGRect(x: 0, y: 0, width: (e.width * (1 + p[0] + p[2])).rounded(), height: (e.height * (1 + p[1] + p[3])).rounded())
            let c = s.canvasColor ?? []
            let bg = c.count >= 3 ? CIImage(color: CIColor(red: CGFloat(c[0]), green: CGFloat(c[1]), blue: CGFloat(c[2]),
                                                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!).cropped(to: full)
                                  : CIImage(color: .clear).cropped(to: full)
            out = out.transformed(by: .init(translationX: l - e.minX, y: b - e.minY)).composited(over: bg).cropped(to: full)
        }
        return out
    }

    /// 캔버스 여백의 왼쪽·아래 폭 (원본 픽셀)
    static func padOffset(_ s: DevelopSettings, native: CGSize) -> CGPoint {
        guard let p = s.canvasPad, p.count == 4 else { return .zero }
        let f = frameSize(s, native: native)
        return CGPoint(x: (f.width * s.crop.w).rounded() * p[0], y: (f.height * s.crop.h).rounded() * p[1])
    }

    // MARK: - 좌표 변환 (원본 픽셀 기준)

    /// 디코딩 이미지 좌표 → 화면에 보이는 이미지 좌표.
    static func toDisplay(_ p: CGPoint, _ s: DevelopSettings, native: CGSize, fullFrame: Bool) -> CGPoint {
        let (turn, size) = turnTransform(s, w: native.width, h: native.height)
        var q = p.applying(turn)
        if s.rotation != 0 { q = q.applying(rotationTransform(s.rotation, w: size.width, h: size.height)) }
        if hasKeystone(s) {
            q = keystoneHomography(v: s.keystoneV, h: s.keystoneH, aspect: s.keystoneAspect,
                                   w: size.width, h: size.height).apply(q)
        }
        var frame = size
        if let pq = perspectiveQuad(s) { q = perspectiveHomography(pq).apply(q); frame = perspectiveSize(pq) }
        if !fullFrame {
            q.x -= frame.width * s.crop.x; q.y -= frame.height * s.crop.y
            let o = padOffset(s, native: native); q.x += o.x; q.y += o.y
        }
        return q
    }

    /// 화면에 보이는 이미지 좌표 → 디코딩 이미지 좌표. 리터칭 점을 사진 내용에 붙여 두는 데 쓴다.
    static func fromDisplay(_ p: CGPoint, _ s: DevelopSettings, native: CGSize, fullFrame: Bool) -> CGPoint {
        let (turn, size) = turnTransform(s, w: native.width, h: native.height)
        var q = p
        let pq = perspectiveQuad(s)
        let frame = pq.map(perspectiveSize) ?? size
        if !fullFrame {
            let o = padOffset(s, native: native); q.x -= o.x; q.y -= o.y
            q.x += frame.width * s.crop.x; q.y += frame.height * s.crop.y
        }
        if let pq { q = perspectiveHomography(pq).inverse.apply(q) }
        if hasKeystone(s) {
            q = keystoneHomography(v: s.keystoneV, h: s.keystoneH, aspect: s.keystoneAspect,
                                   w: size.width, h: size.height).inverse.apply(q)
        }
        if s.rotation != 0 { q = q.applying(rotationTransform(s.rotation, w: size.width, h: size.height).inverted()) }
        return q.applying(turn.inverted())
    }

    /// 선 긋기 키스톤: 두 선(화면 좌표)이 세로가 되도록 세로 키스톤과 미세 회전을 찾는다.
    /// 선을 틀(90° 회전 뒤, 미세 회전 전) 좌표로 되돌린 뒤 두 값을 격자로 찾고 좁혀 간다.
    static func solveVerticals(_ lines: [(CGPoint, CGPoint)], _ s: DevelopSettings, native: CGSize,
                               fullFrame: Bool) -> (keystoneV: Float, rotation: Float) {
        let r = solveKeystone(vertical: framedLines(lines, s, native: native, fullFrame: fullFrame), horizontal: [],
                              s, native: native)
        return (r.v, r.rotation)
    }
}

/// 3×3 투영 변환. 네 점 짝에서 구한다.
struct Homography {
    var m: [Double]

    init(m: [Double]) { self.m = m }

    init(from src: [CGPoint], to dst: [CGPoint]) {
        // h33 = 1로 두고 8원 1차 연립방정식을 푼다.
        var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let x = Double(src[i].x), y = Double(src[i].y), u = Double(dst[i].x), v = Double(dst[i].y)
            a[2 * i] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            a[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }
        for col in 0..<8 {
            let piv = (col..<8).max { abs(a[$0][col]) < abs(a[$1][col]) }!
            a.swapAt(col, piv)
            let d = a[col][col]
            guard abs(d) > 1e-12 else { m = [1, 0, 0, 0, 1, 0, 0, 0, 1]; return }
            for j in col..<9 { a[col][j] /= d }
            for r in 0..<8 where r != col {
                let f = a[r][col]
                if f != 0 { for j in col..<9 { a[r][j] -= f * a[col][j] } }
            }
        }
        m = (0..<8).map { a[$0][8] } + [1]
    }

    func apply(_ p: CGPoint) -> CGPoint {
        let x = Double(p.x), y = Double(p.y)
        let w = m[6] * x + m[7] * y + m[8]
        return CGPoint(x: (m[0] * x + m[1] * y + m[2]) / w, y: (m[3] * x + m[4] * y + m[5]) / w)
    }

    var inverse: Homography {
        let a = m
        let c0 = a[4] * a[8] - a[5] * a[7], c1 = a[5] * a[6] - a[3] * a[8], c2 = a[3] * a[7] - a[4] * a[6]
        let det = a[0] * c0 + a[1] * c1 + a[2] * c2
        let inv = [c0, a[2] * a[7] - a[1] * a[8], a[1] * a[5] - a[2] * a[4],
                   c1, a[0] * a[8] - a[2] * a[6], a[2] * a[3] - a[0] * a[5],
                   c2, a[1] * a[6] - a[0] * a[7], a[0] * a[4] - a[1] * a[3]].map { $0 / det }
        return Homography(m: inv)
    }
}
