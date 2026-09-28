import AppKit
import CoreImage
import simd

/// 변형: 이미지 레이어를 자유 변형(원근·왜곡·기울이기), 뒤틀기 격자(4×4 베지어), 퍼펫 핀(MLS 강체 변형)으로
/// 움직인다. 그림을 작은 칸(격자)으로 나눠 칸마다 원근 변환으로 붙인다 (칸이 작아 곡면도 매끄럽다).
struct LiquifyStroke: Equatable, Hashable, Codable {
    /// 0 밀기, 1 부풀리기, 2 오목, 3 시계 방향 돌리기, 4 반시계, 5 되돌리기
    var tool: Int
    var points: [Double]      // 원본 좌표 x, y 반복
    var radius: Double
    var strength: Double = 0.5
}

enum Warp {
    // MARK: - 원래 자리 (자리·크기·회전)

    /// 그림 좌표(0~1) → 원본 좌표 (기본 자리)
    static func basePoint(_ im: LayerImage, aspect: Double, _ u: Double, _ v: Double) -> CGPoint {
        let w = im.width, h = im.height ?? im.width * aspect
        let a = im.rotation * .pi / 180
        let x = (u - 0.5) * w, y = (v - 0.5) * h
        return CGPoint(x: im.cx + x * cos(a) - y * sin(a), y: im.cy + x * sin(a) + y * cos(a))
    }

    /// 네 모서리 (왼아래, 오른아래, 오른위, 왼위) — 자유 변형 틀의 처음 값
    static func corners(_ im: LayerImage, aspect: Double) -> [CGPoint] {
        if let q = im.quad, q.count == 8 { return (0 ..< 4).map { CGPoint(x: q[$0 * 2], y: q[$0 * 2 + 1]) } }
        return [(0.0, 0.0), (1, 0), (1, 1), (0, 1)].map { basePoint(im, aspect: aspect, $0.0, $0.1) }
    }

    /// 뒤틀기 격자의 처음 값 (4×4, 아래 줄부터): 지금 자리를 고르게 나눈 것 → 베지어 곡면이 그대로 평면
    static func identityMesh(_ im: LayerImage, aspect: Double) -> [Double] {
        var out: [Double] = []
        for j in 0 ..< 4 { for i in 0 ..< 4 {
            let p = map(im, aspect: aspect, Double(i) / 3, Double(j) / 3, useMesh: false, usePins: false)
            out += [p.x, p.y]
        } }
        return out
    }

    static func bern(_ i: Int, _ t: Double) -> Double {
        let s = 1 - t
        switch i { case 0: return s * s * s; case 1: return 3 * t * s * s; case 2: return 3 * t * t * s; default: return t * t * t }
    }

    /// 그림 좌표(0~1) → 원본 좌표 (자유 변형·뒤틀기·핀을 모두 건 자리)
    static func map(_ im: LayerImage, aspect: Double, _ u: Double, _ v: Double, useMesh: Bool = true, usePins: Bool = true) -> CGPoint {
        var p: CGPoint
        if useMesh, let m = im.mesh, m.count == 32 {
            var x = 0.0, y = 0.0
            for j in 0 ..< 4 { for i in 0 ..< 4 {
                let b = bern(i, u) * bern(j, v)
                x += b * m[(j * 4 + i) * 2]; y += b * m[(j * 4 + i) * 2 + 1]
            } }
            p = CGPoint(x: x, y: y)
        } else if let q = im.quad, q.count == 8 {
            let c = (0 ..< 4).map { CGPoint(x: q[$0 * 2], y: q[$0 * 2 + 1]) }
            let h = Homography(from: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)], to: c)
            p = h.apply(CGPoint(x: u, y: v))
        } else {
            p = basePoint(im, aspect: aspect, u, v)
        }
        if usePins, let pins = im.pins, pins.count >= 4 { p = mls(p, pins) }
        return p
    }

    /// 움직이는 최소 제곱 강체 변형 (Schaefer 2006): 핀 (원래 x, y, 옮긴 x, y) 반복
    static func mls(_ v: CGPoint, _ pins: [Double]) -> CGPoint {
        let n = pins.count / 4
        guard n > 0 else { return v }
        if n == 1 { return CGPoint(x: v.x + pins[2] - pins[0], y: v.y + pins[3] - pins[1]) }
        var wsum = 0.0, ps = SIMD2<Double>(0, 0), qs = SIMD2<Double>(0, 0)
        var w = [Double](repeating: 0, count: n)
        let vv = SIMD2<Double>(v.x, v.y)
        for k in 0 ..< n {
            let p = SIMD2(pins[k * 4], pins[k * 4 + 1])
            let d = simd_length_squared(p - vv)
            if d < 1e-8 { return CGPoint(x: pins[k * 4 + 2], y: pins[k * 4 + 3]) }
            w[k] = 1 / d
            wsum += w[k]; ps += w[k] * p; qs += w[k] * SIMD2(pins[k * 4 + 2], pins[k * 4 + 3])
        }
        ps /= wsum; qs /= wsum
        var frot = SIMD2<Double>(0, 0)
        for k in 0 ..< n {
            let ph = SIMD2(pins[k * 4], pins[k * 4 + 1]) - ps, qh = SIMD2(pins[k * 4 + 2], pins[k * 4 + 3]) - qs
            let vp = vv - ps
            // (ph, -ph⊥) (vp, -vp⊥)ᵀ 곱의 행
            let a = SIMD2(ph.x, ph.y), b = SIMD2(ph.y, -ph.x)
            let c = SIMD2(vp.x, vp.y), d = SIMD2(vp.y, -vp.x)
            let m00 = simd_dot(a, c), m01 = simd_dot(a, d), m10 = simd_dot(b, c), m11 = simd_dot(b, d)
            frot += w[k] * SIMD2(qh.x * m00 + qh.y * m10, qh.x * m01 + qh.y * m11)
        }
        let len = simd_length(frot)
        guard len > 1e-9 else { return CGPoint(x: vv.x - ps.x + qs.x, y: vv.y - ps.y + qs.y) }
        let r = frot / len * simd_length(vv - ps) + qs
        return CGPoint(x: r.x, y: r.y)
    }

    static func needsMesh(_ im: LayerImage) -> Bool { im.quad != nil || im.mesh != nil || (im.pins?.count ?? 0) >= 4 }

    /// 칸마다 원근 변환으로 붙인다. 결과는 원본 좌표 × scale.
    /// canvas: 결과를 그릴 영역 (보통 원본 좌표 전체 × scale). 커널을 이 영역 전체에 걸고 바깥은 커널이 투명으로 낸다
    /// (결과를 작은 사각형으로 자른 뒤 겹치면 코어 이미지가 가장자리를 바깥으로 늘여 그리는 일이 있었다)
    static func render(_ src: CIImage, _ im: LayerImage, scale: CGFloat, canvas: CGRect? = nil) -> CIImage {
        let e = src.extent
        let aspect = Double(e.height / max(e.width, 1))
        // 자유 변형만이면 한 번에
        if im.mesh == nil, (im.pins?.count ?? 0) < 4, let q = im.quad, q.count == 8 {
            let c = (0 ..< 4).map { CGPoint(x: q[$0 * 2] * scale, y: q[$0 * 2 + 1] * scale) }
            return src.applyingFilter("CIPerspectiveTransform", parameters: [
                "inputBottomLeft": CIVector(cgPoint: c[0]), "inputBottomRight": CIVector(cgPoint: c[1]),
                "inputTopRight": CIVector(cgPoint: c[2]), "inputTopLeft": CIVector(cgPoint: c[3])])
        }
        // 격자를 역방향 UV 지도로 그려 한 번에 읽는다 (칸마다 붙이면 이음매가 보였다)
        let n = 32
        var grid = [[CGPoint]](repeating: [], count: n + 1)
        for j in 0 ... n { for i in 0 ... n {
            let p = map(im, aspect: aspect, Double(i) / Double(n), Double(j) / Double(n))
            grid[j].append(CGPoint(x: p.x * scale, y: p.y * scale))
        } }
        let all = grid.flatMap { $0 }
        let bx0 = all.map(\.x).min()!, bx1 = all.map(\.x).max()!, by0 = all.map(\.y).min()!, by1 = all.map(\.y).max()!
        let box = CGRect(x: bx0, y: by0, width: max(bx1 - bx0, 1), height: max(by1 - by0, 1)).integral
        if ProcessInfo.processInfo.environment["DUOCHROME_WARP_DEBUG"] != nil { NSLog("warp box %@ src %@", "\(box)", "\(e)") }
        let M = 768
        let mk = CGFloat(M) / max(box.width, box.height)
        let mw = max(Int((box.width * mk).rounded(.up)), 2), mh = max(Int((box.height * mk).rounded(.up)), 2)
        var uvmap = [Float](repeating: 0, count: mw * mh * 4)
        func tri(_ a: (CGPoint, SIMD2<Float>), _ b: (CGPoint, SIMD2<Float>), _ c: (CGPoint, SIMD2<Float>)) {
            // 지도 픽셀 좌표 (아래가 0)
            func m(_ p: CGPoint) -> SIMD2<Float> { SIMD2(Float((p.x - box.minX) * mk), Float((p.y - box.minY) * mk)) }
            let pa = m(a.0), pb = m(b.0), pc = m(c.0)
            let den = (pb.y - pc.y) * (pa.x - pc.x) + (pc.x - pb.x) * (pa.y - pc.y)
            guard abs(den) > 1e-9 else { return }
            let x0 = max(Int(floor(min(pa.x, pb.x, pc.x))) - 1, 0), x1 = min(Int(ceil(max(pa.x, pb.x, pc.x))) + 1, mw - 1)
            let y0 = max(Int(floor(min(pa.y, pb.y, pc.y))) - 1, 0), y1 = min(Int(ceil(max(pa.y, pb.y, pc.y))) + 1, mh - 1)
            guard x0 <= x1, y0 <= y1 else { return }
            for y in y0 ... y1 { for x in x0 ... x1 {
                let q = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
                let w0 = ((pb.y - pc.y) * (q.x - pc.x) + (pc.x - pb.x) * (q.y - pc.y)) / den
                let w1 = ((pc.y - pa.y) * (q.x - pc.x) + (pa.x - pc.x) * (q.y - pc.y)) / den
                let w2 = 1 - w0 - w1
                // 가장자리 반 칸까지 넉넉히 (틈이 없게)
                guard w0 > -0.02, w1 > -0.02, w2 > -0.02 else { continue }
                let uv = a.1 * w0 + b.1 * w1 + c.1 * w2
                // 비트맵은 위 줄부터
                let i = ((mh - 1 - y) * mw + x) * 4
                uvmap[i] = uv.x; uvmap[i + 1] = uv.y; uvmap[i + 3] = 1
            } }
        }
        for j in 0 ..< n { for i in 0 ..< n {
            let u0 = Float(i) / Float(n), u1 = Float(i + 1) / Float(n), v0 = Float(j) / Float(n), v1 = Float(j + 1) / Float(n)
            let p00 = (grid[j][i], SIMD2(u0, v0)), p10 = (grid[j][i + 1], SIMD2(u1, v0))
            let p11 = (grid[j + 1][i + 1], SIMD2(u1, v1)), p01 = (grid[j + 1][i], SIMD2(u0, v1))
            tri(p00, p10, p11); tri(p00, p11, p01)
        } }
        let data = uvmap.withUnsafeBufferPointer { Data(buffer: $0) }
        let mapImg = CIImage(bitmapData: data, bytesPerRow: mw * 16, size: CGSize(width: mw, height: mh), format: .RGBAf, colorSpace: nil)
        guard let k = uvK else { return src }
        let clamped = src
        let area = canvas ?? box
        return k.apply(extent: area, roiCallback: { idx, _ in idx == 0 ? e : mapImg.extent }, arguments: [
            clamped, mapImg, CIVector(x: box.minX, y: box.minY), mk, CIVector(cgRect: e), CIVector(x: CGFloat(mw), y: CGFloat(mh)),
        ]) ?? src
    }

    static let uvK = try? CIKernel(source: """
        kernel vec4 k(sampler s, sampler m, vec2 origin, float mk, vec4 e, vec2 msz) {
            vec2 mp = (destCoord() - origin) * mk;
            if (mp.x < 0.0 || mp.y < 0.0 || mp.x > msz.x || mp.y > msz.y) return vec4(0.0);
            vec4 uv = sample(m, samplerTransform(m, mp));
            if (uv.a < 0.02) return vec4(0.0);
            vec2 st = uv.rg / max(uv.a, 1e-4);
            vec4 c = sample(s, samplerTransform(s, e.xy + st * e.zw));
            return c * smoothstep(0.35, 0.65, uv.a);
        }
        """)

    // MARK: - 유동화

    private static var fieldCache: [String: CIImage] = [:]
    private static let lock = NSLock()

    /// 변위장 (원본 좌표를 cell로 나눈 칸마다 뒤로 읽을 양 dx, dy): 붓질을 차례로 쌓는다
    static func field(_ strokes: [LiquifyStroke], native: CGSize, cell: CGFloat) -> CIImage? {
        let key = "\(strokes.hashValue)|\(native)|\(cell)"
        lock.lock(); defer { lock.unlock() }
        if let f = fieldCache[key] { return f }
        let w = Int((native.width / cell).rounded(.up)) + 1, h = Int((native.height / cell).rounded(.up)) + 1
        var dx = [Float](repeating: 0, count: w * h), dy = dx
        func sample(_ a: [Float], _ x: Float, _ y: Float) -> Float {
            let xi = min(max(Int(x), 0), w - 2), yi = min(max(Int(y), 0), h - 2)
            let fx = min(max(x - Float(xi), 0), 1), fy = min(max(y - Float(yi), 0), 1)
            let a0 = a[yi * w + xi] * (1 - fx) + a[yi * w + xi + 1] * fx
            let a1 = a[(yi + 1) * w + xi] * (1 - fx) + a[(yi + 1) * w + xi + 1] * fx
            return a0 * (1 - fy) + a1 * fy
        }
        for s in strokes {
            let pts = stride(from: 0, to: s.points.count - 1, by: 2).map { CGPoint(x: s.points[$0], y: s.points[$0 + 1]) }
            guard let first = pts.first else { continue }
            // 붓 간격: 반지름의 1/4마다 한 번
            var dabs: [(CGPoint, CGPoint)] = [(first, .zero)]
            var prev = first
            for p in pts.dropFirst() {
                let d = hypot(p.x - prev.x, p.y - prev.y)
                let step = max(s.radius * 0.25, 1)
                if d >= step {
                    let k = Int(d / step)
                    for t in 1 ... k {
                        let f = CGFloat(t) / CGFloat(k)
                        let q = CGPoint(x: prev.x + (p.x - prev.x) * f, y: prev.y + (p.y - prev.y) * f)
                        dabs.append((q, CGPoint(x: (p.x - prev.x) / CGFloat(k), y: (p.y - prev.y) / CGFloat(k))))
                    }
                    prev = p
                }
            }
            if s.tool != 0, pts.count == 1 { for _ in 0 ..< 6 { dabs.append((first, .zero)) } }   // 누르고 있기
            let r = Float(s.radius / Double(cell)), st = Float(s.strength)
            for (c0, mv) in dabs {
                let cx = Float(c0.x / cell), cy = Float(c0.y / cell)
                let x0 = max(Int(cx - r), 0), x1 = min(Int(cx + r) + 1, w - 1)
                let y0 = max(Int(cy - r), 0), y1 = min(Int(cy + r) + 1, h - 1)
                guard x0 <= x1, y0 <= y1 else { continue }
                var ndx = dx, ndy = dy
                for y in y0 ... y1 { for x in x0 ... x1 {
                    let ox = Float(x) - cx, oy = Float(y) - cy
                    let d2 = (ox * ox + oy * oy) / (r * r)
                    guard d2 < 1 else { continue }
                    let fall = (1 - d2) * (1 - d2)
                    var ux: Float = 0, uy: Float = 0   // 이 칸이 뒤로 읽을 추가량 (칸 단위)
                    switch s.tool {
                    case 0: ux = -Float(mv.x / cell) * fall * st * 1.6; uy = -Float(mv.y / cell) * fall * st * 1.6
                    case 1: ux = -ox * fall * st * 0.08; uy = -oy * fall * st * 0.08
                    case 2: ux = ox * fall * st * 0.08; uy = oy * fall * st * 0.08
                    case 3, 4:
                        let a: Float = (s.tool == 3 ? 1 : -1) * fall * st * 0.06
                        ux = -oy * a; uy = ox * a
                    default:
                        // 되돌리기: 원래로 끌어당긴다
                        let i = y * w + x
                        ndx[i] = dx[i] * (1 - fall * st * 0.3); ndy[i] = dy[i] * (1 - fall * st * 0.3)
                        continue
                    }
                    let i = y * w + x
                    // 새 변위 = 이번 이동 + (이동한 자리의) 예전 변위
                    ndx[i] = ux + sample(dx, Float(x) + ux, Float(y) + uy)
                    ndy[i] = uy + sample(dy, Float(x) + ux, Float(y) + uy)
                } }
                dx = ndx; dy = ndy
            }
        }
        var px = [Float](repeating: 0, count: w * h * 4)
        for i in 0 ..< w * h { px[i * 4] = dx[i] * Float(cell); px[i * 4 + 1] = dy[i] * Float(cell); px[i * 4 + 3] = 1 }
        // CIImage 비트맵은 위 줄부터라 뒤집어 넣는다
        var flipped = [Float](repeating: 0, count: w * h * 4)
        for y in 0 ..< h { for x in 0 ..< w * 4 { flipped[(h - 1 - y) * w * 4 + x] = px[y * w * 4 + x] } }
        let data = flipped.withUnsafeBufferPointer { Data(buffer: $0) }
        let img = CIImage(bitmapData: data, bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: nil)
        if fieldCache.count > 8 { fieldCache.removeAll() }
        fieldCache[key] = img
        return img
    }

    static let liquifyK = try? CIKernel(source: """
        kernel vec4 k(sampler s, sampler f, float cell, float scale) {
            vec2 p = destCoord();
            vec2 d = sample(f, samplerTransform(f, p / (cell * scale))).rg;
            return sample(s, samplerTransform(s, p + d * scale));
        }
        """)

    /// 원본 좌표 × scale 그림에 유동화를 건다
    static func liquify(_ img: CIImage, strokes: [LiquifyStroke], native: CGSize, scale: CGFloat) -> CIImage {
        guard !strokes.isEmpty, let k = liquifyK else { return img }
        let cell = max(4, max(native.width, native.height) / 1200)
        guard let f = field(strokes, native: native, cell: cell) else { return img }
        let e = img.extent
        let fs = f.samplingLinear()
        return k.apply(extent: e, roiCallback: { i, r in i == 0 ? e : fs.extent }, arguments: [img.clampedToExtent(), fs, cell, scale])?.cropped(to: e) ?? img
    }
}
