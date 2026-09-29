import Foundation
import simd

/// PSD adjustment layer data → color function (sRGB gamma values 0–1 → 0–1).
/// On import this function is baked into a 33³ .cube LUT on an adjustment layer. Formulas were matched against the spec's data layout
/// and against the merged image stored in PSD files (SelfTest 21).
enum PSDAdjust {
    typealias Fn = (SIMD3<Float>) -> SIMD3<Float>

    /// Adjustment keys converted to LUTs
    static let keys: Set<String> = ["levl", "curv", "hue2", "brit", "CgEd", "blnc", "selc", "mixr", "phfl", "grdm", "expA", "vibA", "blwh", "nvrt", "post", "thrs"]
    static let titles: [String: String] = [
        "levl": "레벨", "curv": "커브", "hue2": "색조/채도", "brit": "명도/대비", "CgEd": "명도/대비", "blnc": "색상 균형",
        "selc": "선택 색상", "mixr": "채널 혼합", "phfl": "포토 필터", "grdm": "그라디언트 맵", "expA": "노출",
        "vibA": "활기", "blwh": "흑백", "nvrt": "반전", "post": "포스터화", "thrs": "한계값", "clrL": "색상 검색",
    ]

    static func function(_ key: String, _ d: Data, blocks: [(key: String, data: Data)] = []) -> Fn? {
        var r = PSD.Reader(d)
        do {
            switch key {
            case "nvrt": return { 1 - $0 }
            case "post":
                let n = Float(max(2, try r.u16()))
                return { v in simd_clamp(floor(v * n), SIMD3(repeating: 0), SIMD3(repeating: n - 1)) / (n - 1) }
            case "thrs":
                let t = Float(try r.u16())
                return { v in
                    let y = (0.299 * v.x + 0.587 * v.y + 0.114 * v.z) * 255
                    return SIMD3(repeating: y >= t ? 1 : 0)
                }
            case "levl": return try levels(&r)
            case "curv": return try curves(&r)
            case "hue2": return try hueSat(&r)
            case "brit", "CgEd":
                // New-style values are in the CgEd descriptor, old-style in brit
                var b: Float = 0, c: Float = 0, legacy = false
                if let ce = blocks.first(where: { $0.key == "CgEd" })?.data, let desc = PSD.versionedDescriptor(ce) {
                    b = Float(desc.double("Brgh") ?? 0); c = Float(desc.double("Cntr") ?? 0)
                    legacy = desc["useLegacy"]?.bool ?? false
                } else {
                    b = Float(try r.i16()); c = Float(try r.i16()); legacy = true
                }
                return brightnessContrast(b, c, legacy: legacy)
            case "blnc": return try colorBalance(&r)
            case "selc": return try selectiveColor(&r)
            case "mixr": return try mixer(&r)
            case "phfl": return try photoFilter(&r)
            case "grdm": return try gradientMap(&r)
            case "expA":
                _ = try r.u16()
                let e = try r.f32(), o = try r.f32(), g = try r.f32()
                // Exposure: multiply in the 2.2-power space, add the offset, then back by 1/(2.2×gamma)
                return { v in
                    let lin = v.pow(2.2) * pow(2, e) + o
                    return simd_max(lin, SIMD3(repeating: 0)).pow(1 / (2.2 * max(g, 0.01)))
                }
            case "vibA":
                guard let desc = PSD.versionedDescriptor(d) else { return nil }
                return vibrance(Float(desc.double("vibrance") ?? 0), Float(desc.double("Strt") ?? 0))
            case "blwh":
                guard let desc = PSD.versionedDescriptor(d) else { return nil }
                return blackWhite(desc)
            default: return nil
            }
        } catch { return nil }
    }

    // MARK: - Gamma

    static func toLinear(_ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(lin(v.x), lin(v.y), lin(v.z))
    }
    static func toGamma(_ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(gam(v.x), gam(v.y), gam(v.z))
    }
    static func lin(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func gam(_ c: Float) -> Float { let x = max(c, 0); return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055 }

    static func luma(_ v: SIMD3<Float>) -> Float { 0.3 * v.x + 0.59 * v.y + 0.11 * v.z }

    // MARK: - Levels

    private static func levels(_ r: inout PSD.Reader) throws -> Fn {
        _ = try r.u16()
        var recs: [(Float, Float, Float, Float, Float)] = []
        for _ in 0 ..< 4 {
            let a = Float(try r.u16()), b = Float(try r.u16()), c = Float(try r.u16()), d = Float(try r.u16()), g = Float(try r.u16()) / 100
            recs.append((a / 255, b / 255, c / 255, d / 255, max(g, 0.01)))
        }
        func map(_ x: Float, _ p: (Float, Float, Float, Float, Float)) -> Float {
            let t = min(max((x - p.0) / max(p.1 - p.0, 1e-4), 0), 1)
            return p.2 + (p.3 - p.2) * pow(t, 1 / p.4)
        }
        return { v in
            let c = SIMD3(map(v.x, recs[1]), map(v.y, recs[2]), map(v.z, recs[3]))
            return SIMD3(map(c.x, recs[0]), map(c.y, recs[0]), map(c.z, recs[0]))
        }
    }

    // MARK: - Curves

    /// Natural cubic spline
    static func spline(_ pts: [(Float, Float)]) -> (Float) -> Float {
        let p = pts.sorted { $0.0 < $1.0 }
        let n = p.count
        guard n >= 2 else { return { $0 } }
        if n == 2 {
            return { x in
                let t = (x - p[0].0) / max(p[1].0 - p[0].0, 1e-6)
                return x <= p[0].0 ? p[0].1 : (x >= p[1].0 ? p[1].1 : p[0].1 + t * (p[1].1 - p[0].1))
            }
        }
        var y2 = [Float](repeating: 0, count: n), u = [Float](repeating: 0, count: n)
        for i in 1 ..< n - 1 {
            let sig = (p[i].0 - p[i - 1].0) / (p[i + 1].0 - p[i - 1].0)
            let q = sig * y2[i - 1] + 2
            y2[i] = (sig - 1) / q
            let dd = (p[i + 1].1 - p[i].1) / (p[i + 1].0 - p[i].0) - (p[i].1 - p[i - 1].1) / (p[i].0 - p[i - 1].0)
            u[i] = (6 * dd / (p[i + 1].0 - p[i - 1].0) - sig * u[i - 1]) / q
        }
        for k in stride(from: n - 2, through: 0, by: -1) { y2[k] = y2[k] * y2[k + 1] + u[k] }
        return { x in
            if x <= p[0].0 { return p[0].1 }
            if x >= p[n - 1].0 { return p[n - 1].1 }
            var lo = 0, hi = n - 1
            while hi - lo > 1 { let m = (lo + hi) / 2; if p[m].0 > x { hi = m } else { lo = m } }
            let h = p[hi].0 - p[lo].0
            let a = (p[hi].0 - x) / h, b = (x - p[lo].0) / h
            let y = a * p[lo].1 + b * p[hi].1 + ((a * a * a - a) * y2[lo] + (b * b * b - b) * y2[hi]) * h * h / 6
            return min(max(y, 0), 1)
        }
    }

    private static func curves(_ r: inout PSD.Reader) throws -> Fn {
        _ = try r.u8()
        _ = try r.u16()
        let bits = try r.u32()
        var fns: [Int: (Float) -> Float] = [:]
        for ch in 0 ..< 32 where bits & (1 << UInt32(ch)) != 0 {
            let n = Int(try r.u16())
            var pts: [(Float, Float)] = []
            for _ in 0 ..< n {
                let out = Float(try r.u16()) / 255, inp = Float(try r.u16()) / 255
                pts.append((inp, out))
            }
            fns[ch] = spline(pts)
        }
        let id: (Float) -> Float = { $0 }
        let m = fns[0] ?? id, rr = fns[1] ?? id, gg = fns[2] ?? id, bb = fns[3] ?? id
        return { v in SIMD3(m(rr(v.x)), m(gg(v.y)), m(bb(v.z))) }
    }

    // MARK: - Hue/Saturation

    static func rgbToHSL(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let mx = v.max(), mn = v.min()
        let l = (mx + mn) / 2
        guard mx - mn > 1e-6 else { return SIMD3(0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Float
        if mx == v.x { h = (v.y - v.z) / d + (v.y < v.z ? 6 : 0) } else if mx == v.y { h = (v.z - v.x) / d + 2 } else { h = (v.x - v.y) / d + 4 }
        return SIMD3(h * 60, s, l)
    }

    static func hslToRGB(_ hsl: SIMD3<Float>) -> SIMD3<Float> {
        let (h, s, l) = (hsl.x, hsl.y, hsl.z)
        guard s > 1e-6 else { return SIMD3(repeating: l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func f(_ t0: Float) -> Float {
            var t = t0
            if t < 0 { t += 1 }; if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        let hh = h / 360
        return SIMD3(f(hh + 1 / 3), f(hh), f(hh - 1 / 3))
    }

    private static func hueSat(_ r: inout PSD.Reader) throws -> Fn {
        _ = try r.u16()
        let colorize = try r.u8() != 0
        _ = try r.u8()
        let ch = Float(try r.i16()), cs = Float(try r.i16()), cl = Float(try r.i16())
        let mh = Float(try r.i16()), ms = Float(try r.i16()), ml = Float(try r.i16())
        var ranges: [([Float], Float, Float, Float)] = []
        for _ in 0 ..< 6 {
            let rg = [Float(try r.i16()), Float(try r.i16()), Float(try r.i16()), Float(try r.i16())]
            ranges.append((rg, Float(try r.i16()), Float(try r.i16()), Float(try r.i16())))
        }
        func lightness(_ v: SIMD3<Float>, _ l: Float) -> SIMD3<Float> {
            let k = l / 100
            return k >= 0 ? v + (1 - v) * k : v * (1 + k)
        }
        if colorize {
            let hue = ch < 0 ? ch + 360 : ch
            return { v in
                let y = (v.max() + v.min()) / 2
                let c = hslToRGB(SIMD3(hue, cs / 100, y))
                return lightness(c, cl)
            }
        }
        // Color range weight: range (start ramp, start hold, end hold, end ramp) — degrees. Add 360 when crossing 0.
        func weight(_ h: Float, _ rg: [Float]) -> Float {
            var a = rg[0], b = rg[1], c = rg[2], d = rg[3]
            if b < a { b += 360 }; if c < b { c += 360 }; if d < c { d += 360 }
            for hh in [h, h + 360, h - 360] {
                if hh >= b && hh <= c { return 1 }
                if hh > a && hh < b { return (hh - a) / (b - a) }
                if hh > c && hh < d { return (d - hh) / (d - c) }
            }
            _ = a; a = 0
            return 0
        }
        return { v in
            var hsl = rgbToHSL(v)
            var dh = mh, ds = ms, dl = ml
            for (rg, h, s, l) in ranges where h != 0 || s != 0 || l != 0 {
                let w = weight(hsl.x, rg) * min(hsl.y * 4, 1)
                dh += h * w; ds += s * w; dl += l * w
            }
            hsl.x = (hsl.x + dh).truncatingRemainder(dividingBy: 360)
            if hsl.x < 0 { hsl.x += 360 }
            let k = ds / 100
            hsl.y = k >= 0 ? min(hsl.y + (1 - hsl.y) * k * hsl.y, 1) : hsl.y * (1 + k)
            return lightness(hslToRGB(hsl), dl)
        }
    }

    // MARK: - Brightness/Contrast

    private static func brightnessContrast(_ b: Float, _ c: Float, legacy: Bool) -> Fn {
        if legacy {
            return { v in
                let x = v + b / 255
                return (x - 0.5) * (1 + c / 100) + 0.5
            }
        }
        // New style (approximation fitted to PSD merged images): brightness is a two-point curve with fixed ends, contrast an S-curve through (64, 64−c/4)·(191, 191+c/4)
        let anchors: [(Float, Float, Float, Float, Float)] = [   // brightness, slope, point 1 x, point 2 x, point 2 y
            (-150, 0.45, 0.8, 0.95, 0.72), (-60, 0.74, 0.78, 0.94, 0.8172), (0, 1, 0.33, 0.66, 0.66),
            (40, 1.28, 0.32, 0.81, 0.9196), (150, 2.04, 0.45, 0.55, 0.958),
        ]
        var bright: (Float) -> Float = { $0 }
        if b != 0 {
            let bb = min(max(b, -150), 150)
            let i = max(0, min(anchors.count - 2, (anchors.lastIndex { $0.0 <= bb } ?? 0)))
            let a0 = anchors[i], a1 = anchors[i + 1]
            let t = (bb - a0.0) / (a1.0 - a0.0)
            func lerp(_ x: Float, _ y: Float) -> Float { x + (y - x) * t }
            let k = lerp(a0.1, a1.1), p = lerp(a0.2, a1.2), q = lerp(a0.3, a1.3), y2 = lerp(a0.4, a1.4)
            bright = spline([(0, 0), (p, min(p * k, 0.99)), (max(q, p + 0.02), max(y2, min(p * k, 0.99) + 0.005)), (1, 1)])
        }
        let s = c / 4 / 255
        let contrast: (Float) -> Float = c == 0 ? { $0 } : spline([(0, 0), (64 / 255, 64 / 255 - s), (191 / 255, 191 / 255 + s), (1, 1)])
        return { v in SIMD3(contrast(bright(v.x)), contrast(bright(v.y)), contrast(bright(v.z))) }
    }

    // MARK: - Color Balance

    private static func colorBalance(_ r: inout PSD.Reader) throws -> Fn {
        var v: [[Float]] = []
        for _ in 0 ..< 3 { v.append([Float(try r.i16()) / 100, Float(try r.i16()) / 100, Float(try r.i16()) / 100]) }
        let preserve: Bool = ((try? r.u8()) ?? 1) != 0
        // Approximation fitted to the merged image: shadows/midtones via gamma, highlights via white point (+gamma). Per channel.
        func channel(_ c: Int) -> (Float) -> Float {
            let sh = v[0][c], md = v[1][c], hl = v[2][c]
            let gs = sh >= 0 ? pow(2, -sh * 0.49) : pow(2, -sh * 0.28)
            let black = sh < 0 ? -0.48 * sh : 0
            let gm = pow(2, -md)
            let gh = hl >= 0 ? pow(2, -hl * 0.48) : pow(2, -hl * 0.516)
            let white = hl > 0 ? 1 - 0.4 * hl : 1
            return { x in
                var y = min(x / white, 1)
                y = pow(y, gh)
                y = max(0, (y - black) / (1 - black))
                y = pow(y, gs)
                return pow(y, gm)
            }
        }
        let fr = channel(0), fg = channel(1), fb = channel(2)
        return { c in
            var o = simd_clamp(SIMD3(fr(c.x), fg(c.y), fb(c.z)), SIMD3(repeating: 0), SIMD3(repeating: 1))
            if preserve {
                // Apply the same gamma to all channels to restore HSL lightness (preserve luminosity)
                let target = (c.max() + c.min()) / 2
                var lo: Float = 0.2, hi: Float = 5
                for _ in 0 ..< 14 {
                    let g = (lo + hi) / 2
                    let p = o.pow(g)
                    if (p.max() + p.min()) / 2 > target { lo = g } else { hi = g }
                }
                o = o.pow((lo + hi) / 2)
            }
            return o
        }
    }

    // MARK: - Selective Color

    private static func selectiveColor(_ r: inout PSD.Reader) throws -> Fn {
        _ = try r.u16()
        let absolute = try r.u16() == 1
        var recs: [SIMD4<Float>] = []
        for _ in 0 ..< 10 { recs.append(SIMD4(Float(try r.i16()), Float(try r.i16()), Float(try r.i16()), Float(try r.i16())) / 100) }
        // 1 red, 2 yellow, 3 green, 4 cyan, 5 blue, 6 magenta, 7 white, 8 neutral, 9 black
        return { v in
            let mx = v.max(), mn = v.min()
            let mid = v.x + v.y + v.z - mx - mn
            var w = [Float](repeating: 0, count: 10)
            // primary (largest channel) and complement (smallest channel)
            if mx > mn {
                if v.x == mx { w[1] = mx - mid } else if v.y == mx { w[3] = mx - mid } else { w[5] = mx - mid }
                if v.x == mn { w[4] = mid - mn } else if v.y == mn { w[6] = mid - mn } else { w[2] = mid - mn }
            }
            w[7] = max(0, (mn - 0.5) * 2)
            w[9] = max(0, (0.5 - mx) * 2)
            w[8] = max(0, 1 - (abs(mx - 0.5) + abs(mn - 0.5)))
            var o = v
            for i in 1 ... 9 where w[i] > 0 {
                let a = recs[i]
                for c in 0 ..< 3 {
                    let ink = 1 - v[c]
                    let amt = a[c]
                    var d = absolute ? amt : amt * ink
                    d += absolute ? a.w : a.w * ink
                    // Adding ink (+) darkens the channel
                    let lim: Float = d > 0 ? v[c] : 1 - v[c]
                    o[c] -= w[i] * max(-lim, min(lim, d))
                }
            }
            return simd_clamp(o, SIMD3(repeating: 0), SIMD3(repeating: 1))
        }
    }

    // MARK: - Channel Mixer

    private static func mixer(_ r: inout PSD.Reader) throws -> Fn {
        _ = try r.u16()
        let mono = try r.u16() != 0
        var m: [[Float]] = []
        for _ in 0 ..< 3 {
            let a = Float(try r.i16()), b = Float(try r.i16()), c = Float(try r.i16())
            _ = try r.i16()
            let k = Float(try r.i16())
            m.append([a / 100, b / 100, c / 100, k / 100])
        }
        return { v in
            func row(_ i: Int) -> Float { m[i][0] * v.x + m[i][1] * v.y + m[i][2] * v.z + m[i][3] }
            if mono { let y = row(0); return SIMD3(repeating: y) }
            return simd_clamp(SIMD3(row(0), row(1), row(2)), SIMD3(repeating: 0), SIMD3(repeating: 1))
        }
    }

    // MARK: - Photo Filter

    private static func photoFilter(_ r: inout PSD.Reader) throws -> Fn {
        let ver = try r.u16()
        var color = SIMD3<Float>(0.93, 0.54, 0)
        if ver == 3 {
            // XYZ (4-byte fixed point each) → approximate sRGB
            let x = Float(try r.i32()) / 65536, y = Float(try r.i32()) / 65536, z = Float(try r.i32()) / 65536
            let lin = SIMD3(3.2406 * x - 1.5372 * y - 0.4986 * z, -0.9689 * x + 1.8758 * y + 0.0415 * z, 0.0557 * x - 0.2040 * y + 1.0570 * z) / 100
            color = toGamma(simd_clamp(lin, SIMD3(repeating: 0), SIMD3(repeating: 1)))
        } else {
            let space = try r.u16()
            let a = Float(try r.u16()) / 65535, b = Float(try r.u16()) / 65535, c = Float(try r.u16()) / 65535
            _ = try r.u16()
            if space == 0 { color = SIMD3(a, b, c) }
        }
        let density = Float(try r.u32()) / 100
        let preserve = try r.u8() != 0
        return { v in
            var o = v + (v * color - v) * density
            if preserve {
                let l0 = luma(v), l1 = max(luma(o), 1e-4)
                o *= l0 / l1
            }
            return simd_clamp(o, SIMD3(repeating: 0), SIMD3(repeating: 1))
        }
    }

    // MARK: - Gradient Map

    struct GradientStop { var loc: Float; var mid: Float; var color: SIMD3<Float> }

    /// "Classic" gradient (100% smoothness): per-channel Hermite curve with Catmull–Rom slopes; end slopes are half the one-sided difference
    static func sample(_ stops: [GradientStop], _ t: Float) -> SIMD3<Float> {
        guard let first = stops.first, let last = stops.last else { return SIMD3(repeating: t) }
        if t <= first.loc { return first.color }
        if t >= last.loc { return last.color }
        let n = stops.count
        func slope(_ i: Int) -> SIMD3<Float> {
            if i == 0 { return 0.5 * (stops[1].color - stops[0].color) / max(stops[1].loc - stops[0].loc, 1e-4) }
            if i == n - 1 { return 0.5 * (stops[i].color - stops[i - 1].color) / max(stops[i].loc - stops[i - 1].loc, 1e-4) }
            return (stops[i + 1].color - stops[i - 1].color) / max(stops[i + 1].loc - stops[i - 1].loc, 1e-4)
        }
        for i in 0 ..< n - 1 where t >= stops[i].loc && t <= stops[i + 1].loc {
            let a = stops[i], b = stops[i + 1]
            let h = max(b.loc - a.loc, 1e-6)
            var u = (t - a.loc) / h
            let m = min(max(b.mid, 0.01), 0.99)
            if abs(m - 0.5) > 0.01 { u = pow(u, log(0.5) / log(m)) }
            let u2 = u * u, u3 = u2 * u
            let h00 = 2 * u3 - 3 * u2 + 1, h10 = u3 - 2 * u2 + u, h01 = -2 * u3 + 3 * u2, h11 = u3 - u2
            let c = h00 * a.color + h10 * h * slope(i) + h01 * b.color + h11 * h * slope(i + 1)
            return simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1))
        }
        return last.color
    }

    static func readGradientStops(_ r: inout PSD.Reader) throws -> [GradientStop] {
        let n = Int(try r.u16())
        var stops: [GradientStop] = []
        for _ in 0 ..< n {
            let loc = Float(try r.u32()) / 4096, mid = Float(try r.u32()) / 100
            let mode = try r.u16()
            let a = Float(try r.u16()) / 65535, b = Float(try r.u16()) / 65535, c = Float(try r.u16()) / 65535
            _ = try r.u16(); _ = try r.u16()
            let col = mode == 0 ? SIMD3(a, b, c) : (mode == 1 ? SIMD3(repeating: a) : SIMD3(a, b, c))
            stops.append(GradientStop(loc: loc, mid: mid, color: col))
        }
        return stops
    }

    private static func gradientMap(_ r: inout PSD.Reader) throws -> Fn {
        let ver = try r.u16()
        let reverse = try r.u8() != 0
        _ = try r.u8()
        if ver >= 3 { _ = try r.key() }
        _ = try r.unicode()
        var stops = try readGradientStops(&r)
        if reverse { stops = stops.reversed().map { GradientStop(loc: 1 - $0.loc, mid: 1 - $0.mid, color: $0.color) } }
        return { v in sample(stops, luma(v)) }
    }

    // MARK: - Vibrance

    private static func vibrance(_ vib: Float, _ sat: Float) -> Fn {
        { v in
            var o = v
            if vib != 0 {
                // Keep the strongest channel and push (+) or pull (−) the others. + applies more to less saturated colors.
                let mx = o.max(), s = mx > 0 ? (mx - o.min()) / mx : 0
                let k = vib > 0 ? 1 + 0.2 * vib / 100 * (1 - s * s * s * s) : 1 + 0.67 * vib / 100
                o = mx - (mx - o) * k
            }
            if sat != 0 {
                // Saturation multiplies Lab chroma (C*)
                var lab = toLab(simd_clamp(o, SIMD3(repeating: 0), SIMD3(repeating: 1)))
                lab.y *= 1 + sat / 100; lab.z *= 1 + sat / 100
                o = fromLab(lab)
            }
            return simd_clamp(o, SIMD3(repeating: 0), SIMD3(repeating: 1))
        }
    }

    static func toLab(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let l = toLinear(v)
        let x = (0.4124 * l.x + 0.3576 * l.y + 0.1805 * l.z) / 0.95047
        let y = 0.2126 * l.x + 0.7152 * l.y + 0.0722 * l.z
        let z = (0.0193 * l.x + 0.1192 * l.y + 0.9505 * l.z) / 1.08883
        func f(_ t: Float) -> Float { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
        return SIMD3(116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    static func fromLab(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        let fy = (lab.x + 16) / 116, fx = fy + lab.y / 500, fz = fy - lab.z / 200
        func g(_ t: Float) -> Float { t * t * t > 0.008856 ? t * t * t : (t - 16 / 116) / 7.787 }
        let x = g(fx) * 0.95047, y = g(fy), z = g(fz) * 1.08883
        let r = 3.2406 * x - 1.5372 * y - 0.4986 * z
        let gg = -0.9689 * x + 1.8758 * y + 0.0415 * z
        let b = 0.0557 * x - 0.2040 * y + 1.0570 * z
        return toGamma(simd_clamp(SIMD3(r, gg, b), SIMD3(repeating: 0), SIMD3(repeating: 1)))
    }

    // MARK: - Black & White

    private static func blackWhite(_ d: PSD.Descriptor) -> Fn {
        func w(_ k: String, _ def: Float) -> Float { Float(d.double(k) ?? Double(def)) / 100 }
        let red = w("Rd  ", 40), yel = w("Yllw", 60), grn = w("Grn ", 40), cyn = w("Cyn ", 60), blu = w("Bl  ", 20), mag = w("Mgnt", 80)
        let tint = (d["useTint"]?.bool ?? false) ? PSD.Descriptor.rgb(d.obj("tintColor")) : nil
        return { v in
            let mx = v.max(), mn = v.min()
            let mid = v.x + v.y + v.z - mx - mn
            let primary: Float, secondary: Float
            if v.x == mx { primary = red; secondary = v.y >= v.z ? yel : mag }
            else if v.y == mx { primary = grn; secondary = v.x >= v.z ? yel : cyn }
            else { primary = blu; secondary = v.x >= v.y ? mag : cyn }
            let g = min(max(mn + (mid - mn) * secondary + (mx - mid) * primary, 0), 1)
            if let t = tint {
                let tc = SIMD3(t[0], t[1], t[2])
                var h = rgbToHSL(tc); h.z = g
                return hslToRGB(SIMD3(h.x, h.y * (1 - abs(2 * g - 1)), g))
            }
            return SIMD3(repeating: g)
        }
    }

    // MARK: - LUT

    /// Bakes a color function into .cube text (red changes fastest)
    static func cube(_ f: Fn, size n: Int = 33, title: String = "Duochrome") -> String {
        var s = "TITLE \"\(title)\"\nLUT_3D_SIZE \(n)\n"
        s.reserveCapacity(n * n * n * 28)
        let k = Float(n - 1)
        for b in 0 ..< n { for g in 0 ..< n { for r in 0 ..< n {
            let o = simd_clamp(f(SIMD3(Float(r) / k, Float(g) / k, Float(b) / k)), SIMD3(repeating: 0), SIMD3(repeating: 1))
            s += String(format: "%.5f %.5f %.5f\n", o.x, o.y, o.z)
        } } }
        return s
    }
}

private extension SIMD3 where Scalar == Float {
    func pow(_ e: Float) -> SIMD3<Float> { SIMD3(Foundation.pow(x, e), Foundation.pow(y, e), Foundation.pow(z, e)) }
}
