import CoreImage

/// 키스톤 풀이: 세로여야 할 선·가로여야 할 선을 받아 세로·가로 키스톤과 미세 회전을 찾는다.
/// 선은 틀 좌표(90° 회전 뒤, 미세 회전 전, 원본 픽셀)로 받는다.
extension Geometry {
    enum KeystoneMode: Int, CaseIterable {
        case vertical, horizontal, full
        var title: String { ["세로", "가로", "전체"][rawValue] }
        /// 선 긋기로 받을 선 수 (전체는 세로 둘 + 가로 둘).
        var lineCount: Int { self == .full ? 4 : 2 }
    }

    /// 화면 좌표 선 → 틀 좌표 선.
    static func framedLines(_ lines: [(CGPoint, CGPoint)], _ s: DevelopSettings, native: CGSize,
                            fullFrame: Bool) -> [(CGPoint, CGPoint)] {
        let (turn, _) = turnTransform(s, w: native.width, h: native.height)
        return lines.map { l in
            (fromDisplay(l.0, s, native: native, fullFrame: fullFrame).applying(turn),
             fromDisplay(l.1, s, native: native, fullFrame: fullFrame).applying(turn))
        }
    }

    /// 격자로 찾고 좁혀 간다. 선이 없는 쪽 키스톤은 지금 값을 둔다.
    /// 자동 찾기의 선에는 엉뚱한 선이 섞이므로 한 선이 비용에 주는 몫을 (6°)²에서 자른다.
    static func solveKeystone(vertical: [(CGPoint, CGPoint)], horizontal: [(CGPoint, CGPoint)],
                              _ s: DevelopSettings, native: CGSize, robust: Bool = false)
        -> (v: Float, h: Float, rotation: Float) {
        let (_, size) = turnTransform(s, w: native.width, h: native.height)
        let w = size.width, h = size.height
        let cap = robust ? pow(6.0 * .pi / 180, 2) : .infinity
        func cost(_ v: Float, _ hk: Float, _ r: Float) -> Double {
            let rot = rotationTransform(r, w: w, h: h)
            let hm = keystoneHomography(v: v, h: hk, aspect: s.keystoneAspect, w: w, h: h)
            var c = 0.0
            for (a, b) in vertical {
                let pa = hm.apply(a.applying(rot)), pb = hm.apply(b.applying(rot))
                let ang = atan2(Double(pb.x - pa.x), Double(pb.y - pa.y))   // 세로에서 벗어난 각
                let d = abs(ang) > .pi / 2 ? .pi - abs(ang) : ang
                c += min(d * d, cap)
            }
            for (a, b) in horizontal {
                let pa = hm.apply(a.applying(rot)), pb = hm.apply(b.applying(rot))
                let ang = atan2(Double(pb.y - pa.y), Double(pb.x - pa.x))   // 가로에서 벗어난 각
                let d = abs(ang) > .pi / 2 ? .pi - abs(ang) : ang
                c += min(d * d, cap)
            }
            return c
        }
        let freeV = !vertical.isEmpty, freeH = !horizontal.isEmpty
        var best = (v: s.keystoneV, h: s.keystoneH, r: s.rotation, c: cost(s.keystoneV, s.keystoneH, s.rotation))
        var step = (v: Float(freeH ? 10 : 5), h: Float(freeV ? 10 : 5), r: Float(freeV && freeH ? 2 : 1))
        var lo = (v: freeV ? Float(-100) : s.keystoneV, h: freeH ? Float(-100) : s.keystoneH, r: Float(-45))
        var hi = (v: freeV ? Float(100) : s.keystoneV, h: freeH ? Float(100) : s.keystoneH, r: Float(45))
        for _ in 0..<5 {
            var v = lo.v
            while v <= hi.v {
                var hk = lo.h
                while hk <= hi.h {
                    var r = lo.r
                    while r <= hi.r {
                        let c = cost(v, hk, r)
                        if c < best.c { best = (v, hk, r, c) }
                        r += step.r
                    }
                    hk += freeH ? step.h : 1
                }
                v += freeV ? step.v : 1
            }
            if freeV { lo.v = max(best.v - step.v * 2, -100); hi.v = min(best.v + step.v * 2, 100) }
            if freeH { lo.h = max(best.h - step.h * 2, -100); hi.h = min(best.h + step.h * 2, 100) }
            lo.r = max(best.r - step.r * 2, -45); hi.r = min(best.r + step.r * 2, 45)
            step = (step.v / 5, step.h / 5, step.r / 5)
        }
        return (best.v, best.h, best.r)
    }
}

/// 자동 키스톤용 직선 찾기: 기울기 방향을 아는 허프 변환.
///
/// 소벨 기울기가 가리키는 방향 근처에만 표를 던진다 (방향 제한 허프). 세로 후보는 x = xc + t·(y − cy),
/// 가로 후보는 y = yc + t·(x − cx) 꼴로 찾는다. |t| 한도가 세로 0.4(약 22°), 가로 0.25(약 14°)라
/// 사진 속 먼 쪽으로 달아나는 선(투시가 센 가로선)은 대개 빠진다.
enum LineDetector {
    struct Line { var a: CGPoint; var b: CGPoint; var score: Float }

    /// `image`의 좌표(영역 원점 기준)로 선을 돌려준다.
    static func detect(_ image: CIImage, maxLines: Int = 6) -> (vertical: [Line], horizontal: [Line]) {
        let e = image.extent.integral
        let w = Int(e.width), h = Int(e.height)
        guard w > 16, h > 16 else { return ([], []) }
        var rgba = [Float](repeating: 0, count: w * h * 4)
        Render.context.render(image, toBitmap: &rgba, rowBytes: w * 16, bounds: e, format: .RGBAf,
                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        // 밝기 (행 0 = 위쪽 → 아래가 0이 되게 뒤집어 담는다)
        var lum = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let src = (h - 1 - y) * w
            for x in 0..<w {
                let i = (src + x) * 4
                lum[y * w + x] = 0.299 * rgba[i] + 0.587 * rgba[i + 1] + 0.114 * rgba[i + 2]
            }
        }
        // 소벨
        var gx = [Float](repeating: 0, count: w * h), gy = gx
        var mags: [Float] = []
        mags.reserveCapacity(w * h / 4)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                func L(_ dx: Int, _ dy: Int) -> Float { lum[(y + dy) * w + x + dx] }
                let sx = (L(1, -1) + 2 * L(1, 0) + L(1, 1)) - (L(-1, -1) + 2 * L(-1, 0) + L(-1, 1))
                let sy = (L(-1, 1) + 2 * L(0, 1) + L(1, 1)) - (L(-1, -1) + 2 * L(0, -1) + L(1, -1))
                gx[y * w + x] = sx; gy[y * w + x] = sy
                if (x + y) % 4 == 0 { mags.append(hypot(sx, sy)) }
            }
        }
        mags.sort()
        // 기울기 상위 12%만 표를 던진다.
        let thresh = max(mags.isEmpty ? 0.05 : mags[Int(Double(mags.count) * 0.88)], 0.02)
        let vertical = hough(w: w, h: h, gx: gx, gy: gy, thresh: thresh, transpose: false, tMax: 0.4, maxLines: maxLines)
        let horizontal = hough(w: w, h: h, gx: gx, gy: gy, thresh: thresh, transpose: true, tMax: 0.25, maxLines: maxLines)
        func place(_ l: Line) -> Line { Line(a: CGPoint(x: l.a.x + e.minX, y: l.a.y + e.minY),
                                             b: CGPoint(x: l.b.x + e.minX, y: l.b.y + e.minY), score: l.score) }
        return (vertical.map(place), horizontal.map(place))
    }

    /// transpose가 false면 세로 선 (x = c + t·(y − 가운데)), true면 가로 선 (y = c + t·(x − 가운데)).
    private static func hough(w: Int, h: Int, gx: [Float], gy: [Float], thresh: Float, transpose: Bool,
                              tMax: Float, maxLines: Int) -> [Line] {
        // u: 선을 따라가는 축, v: 선을 가로지르는 축
        let lenU = transpose ? w : h, lenV = transpose ? h : w
        let cu = Float(lenU) / 2
        let tBins = 81, tStep = 2 * tMax / Float(tBins - 1)
        var acc = [Float](repeating: 0, count: tBins * lenV)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let a = gx[i], b = gy[i]
                let m = hypot(a, b)
                guard m > thresh else { continue }
                // 선을 가로지르는 성분(gv)이 선을 따라가는 성분(gu)보다 충분히 커야 한다.
                let gv = transpose ? b : a, gu = transpose ? a : b
                guard abs(gv) > abs(gu) * 1.5 else { continue }
                let tg = -gu / gv      // 선 방향 (t, 1)의 법선 (1, −t)이 기울기와 나란하면 t = −gu/gv
                guard abs(tg) <= tMax + tStep else { continue }
                let u = Float(transpose ? x : y), v = Float(transpose ? y : x)
                let tc = Int(((tg + tMax) / tStep).rounded())
                for ti in max(tc - 2, 0)...min(tc + 2, tBins - 1) {
                    let t = -tMax + Float(ti) * tStep
                    let c = Int((v - t * (u - cu)).rounded())
                    guard c >= 0, c < lenV else { continue }
                    acc[ti * lenV + c] += m
                }
            }
        }
        // 꼭대기 찾기: 가장 큰 칸부터, 이웃(±1.5% 폭, ±4칸 기울기)을 지우며.
        var lines: [Line] = []
        let rc = max(4, lenV / 60)
        var top: Float = 0
        for _ in 0..<maxLines {
            var best = -1; var bv: Float = 0
            for (i, a) in acc.enumerated() where a > bv { bv = a; best = i }
            guard best >= 0 else { break }
            if top == 0 { top = bv }
            // 선 길이 한 변의 20% 이상에 해당하는 기울기 합이 있어야 한다.
            guard bv > top * 0.25, bv > thresh * Float(lenU) * 0.2 else { break }
            let ti = best / lenV, c = best % lenV
            var t = -tMax + Float(ti) * tStep
            // 칸 크기(약 0.6°)보다 정확하게: 선 둘레 3px 안의 가장자리 점으로 v = c + t·(u − cu)를 최소제곱으로 맞춘다.
            var cf = Float(c)
            for _ in 0..<2 {
                var sw: Float = 0, su: Float = 0, sv: Float = 0, suu: Float = 0, suv: Float = 0
                for ui in 1..<(lenU - 1) {
                    let du = Float(ui) - cu
                    let center = cf + t * du
                    let lo = max(Int(center - 3), 1), hi = min(Int(center + 3), lenV - 2)
                    guard lo <= hi else { continue }
                    for vi in lo...hi {
                        let x = transpose ? ui : vi, y = transpose ? vi : ui
                        let i = y * w + x
                        let a = gx[i], b = gy[i]
                        let m = hypot(a, b)
                        guard m > thresh else { continue }
                        let gv = transpose ? b : a, gu = transpose ? a : b
                        guard abs(gv) > abs(gu) * 1.5, abs(-gu / gv - t) < 0.05 else { continue }
                        let fu = du, fv = Float(vi)
                        sw += m; su += m * fu; sv += m * fv; suu += m * fu * fu; suv += m * fu * fv
                    }
                }
                let det = sw * suu - su * su
                guard sw > 0, abs(det) > 1e-6 else { break }
                t = (sw * suv - su * sv) / det
                cf = (sv - t * su) / sw
            }
            let u0: Float = 0, u1 = Float(lenU)
            let v0 = cf + t * (u0 - cu), v1 = cf + t * (u1 - cu)
            let a = transpose ? CGPoint(x: CGFloat(u0), y: CGFloat(v0)) : CGPoint(x: CGFloat(v0), y: CGFloat(u0))
            let b = transpose ? CGPoint(x: CGFloat(u1), y: CGFloat(v1)) : CGPoint(x: CGFloat(v1), y: CGFloat(u1))
            lines.append(Line(a: a, b: b, score: bv / top))
            for tj in max(ti - 4, 0)...min(ti + 4, tBins - 1) {
                for cj in max(c - rc, 0)...min(c + rc, lenV - 1) { acc[tj * lenV + cj] = 0 }
            }
        }
        return lines
    }
}
