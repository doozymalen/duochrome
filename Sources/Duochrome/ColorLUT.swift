import Foundation
import CoreImage

/// One color balance region (one color wheel). Hue 0–360, amount 0–1, luminance -1–1.
struct ColorShift: Equatable, Codable {
    var hue: Float = 0
    var amount: Float = 0
    var lightness: Float = 0
    var isNeutral: Bool { amount == 0 && lightness == 0 }
}

/// Black & white conversion. Six color sensitivities (-100–100) and split toning.
struct BlackWhite: Equatable, Codable {
    var enabled = false
    var red: Float = 0, yellow: Float = 0, green: Float = 0
    var cyan: Float = 0, blue: Float = 0, magenta: Float = 0
    var shadowTone = ColorShift()
    var highlightTone = ColorShift()
}

/// One color editor range. 100% within half the width of the center hue, falling off by the smoothness beyond.
struct ColorRange: Equatable, Codable {
    var name = ""
    var hue: Float
    var width: Float = 45
    var soft: Float = 0.6
    var dHue: Float = 0      // hue shift -30–30°
    var dSat: Float = 0      // saturation -100–100
    var dLight: Float = 0    // lightness -100–100
    /// Range unchecked in the list (value kept, temporarily off)
    var off: Bool? = nil
    var isNeutral: Bool { dHue == 0 && dSat == 0 && dLight == 0 }
    var isActive: Bool { off != true && !isNeutral }

    /// The eight colors of the basic color editor.
    static let basic: [ColorRange] = [("빨강", 0), ("주황", 30), ("노랑", 60), ("초록", 120), ("청록", 180),
                                      ("파랑", 225), ("보라", 270), ("자홍", 315)]
        .map { ColorRange(name: $0.0, hue: $0.1) }

    /// How strongly this color (hue h, saturation s) is affected, 0–1. Near-neutral colors less (so grays aren't tinted).
    func weight(hue h: Float, sat s: Float) -> Float {
        var d = abs(h - hue).truncatingRemainder(dividingBy: 360)
        if d > 180 { d = 360 - d }
        let inner = width / 2, outer = inner + max(width * soft, 1)
        let hw: Float = d <= inner ? 1 : (d >= outer ? 0 : 1 - (d - inner) / (outer - inner))
        let t = min(max((s - 0.03) / 0.12, 0), 1)
        return hw * hw * (3 - 2 * hw) * (t * t * (3 - 2 * t))
    }
}

/// Skin tone uniformity: pulls the spread of hue/saturation/lightness toward the picked skin color.
struct SkinTone: Equatable, Codable {
    var enabled = false
    var hue: Float = 25
    var sat: Float = 0.4
    var light: Float = 0.7
    var width: Float = 40
    var hueAmount: Float = 0     // 0~100
    var satAmount: Float = 0
    var lightAmount: Float = 0
    var isNeutral: Bool { !enabled || (hueAmount == 0 && satAmount == 0 && lightAmount == 0) }
}

/// Bakes global color operations into one 3D LUT. Every per-pixel operation, like color balance and B&W,
/// goes here. A 32³ grid bakes in a few ms, and on the GPU it's a single trilinear lookup.
enum ColorLUT {
    static let size = 32

    struct Key: Equatable, Codable {
        var master = ColorShift(), shadow = ColorShift(), mid = ColorShift(), high = ColorShift()
        var bw = BlackWhite()
        /// Color editor: the first eight are basic colors, the rest are eyedropper ranges (advanced, up to 35).
        var editor: [ColorRange] = ColorRange.basic
        var skin = SkinTone()
        /// Luminance (luma) curve. Supplied from settings' curves.luma at the develop stage.
        var luma = ToneCurve()
        var isNeutral: Bool {
            luma.isIdentity &&
            master.isNeutral && shadow.isNeutral && mid.isNeutral && high.isNeutral && !bw.enabled
                && !editor.contains(where: \.isActive) && skin.isNeutral
        }
    }

    /// A few recent tables (the base develop and adjustment layers each have their own key, so one entry would thrash)
    private static var cache: [(Key, Data)] = []
    private static let cacheLock = NSLock()

    static func apply(_ key: Key, to image: CIImage) -> CIImage {
        guard !key.isNeutral else { return image }
        let data: Data
        cacheLock.lock()
        let hit = cache.firstIndex { $0.0 == key }
        if let i = hit {
            data = cache[i].1
            cache.append(cache.remove(at: i))
            cacheLock.unlock()
        } else {
            cacheLock.unlock()
            data = bake(key)
            cacheLock.lock()
            cache.append((key, data))
            if cache.count > 6 { cache.removeFirst() }
            cacheLock.unlock()
        }
        // Applied in display gamma space, to split region weights by perceived brightness.
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": size,
            "inputCubeData": data,
            "inputColorSpace": Render.displaySpace,
        ])
    }

    /// Unit color along a hue direction. Luminance removed so only color moves and brightness stays.
    private static func chroma(_ hue: Float) -> SIMD3<Float> {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        let c: SIMD3<Float>
        switch Int(h) {
        case 0: c = [1, x, 0]
        case 1: c = [x, 1, 0]
        case 2: c = [0, 1, x]
        case 3: c = [0, x, 1]
        case 4: c = [x, 0, 1]
        default: c = [1, 0, x]
        }
        return c - luma(c)
    }

    private static func luma(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    private static func hue(of c: SIMD3<Float>) -> (hue: Float, sat: Float) {
        let mx = max(c.x, c.y, c.z), mn = min(c.x, c.y, c.z), d = mx - mn
        guard d > 1e-5 else { return (0, 0) }
        var h: Float
        if mx == c.x { h = (c.y - c.z) / d } else if mx == c.y { h = 2 + (c.z - c.x) / d } else { h = 4 + (c.x - c.y) / d }
        h *= 60
        if h < 0 { h += 360 }
        return (h, mx > 0 ? d / mx : 0)
    }

    static func transform(_ key: Key, _ input: SIMD3<Float>) -> SIMD3<Float> {
        var c = input
        let k: Float = 0.25   // how far color moves with the wheel pushed to the edge

        // Luma curve: moves only luminance along the curve, preserving color ratios.
        if !key.luma.isIdentity {
            let table = lumaTable(key.luma)
            let y = min(max(luma(c), 0), 1)
            let f = y * Float(table.count - 1)
            let i = Int(f), j = min(i + 1, table.count - 1), t = f - Float(i)
            let ny = table[i] * (1 - t) + table[j] * t
            c = y > 1e-4 ? c * (ny / y) : SIMD3(repeating: ny)
        }

        // Color balance: shadow/midtone/highlight weights normalized to sum to 1.
        let y = min(max(luma(c), 0), 1)
        let ws = (1 - y) * (1 - y), wh = y * y, wm = 1 - ws - wh
        for (w, s) in [(1, key.master), (ws, key.shadow), (wm, key.mid), (wh, key.high)] where !s.isNeutral {
            c += w * (s.amount * k * chroma(s.hue) + s.lightness * 0.2)
        }

        // Color editor / skin tone: shifted in HSV.
        if key.editor.contains(where: \.isActive) || !key.skin.isNeutral {
            var (h, s, v) = hsv(c)
            var dh: Float = 0, satMul: Float = 1, lightMul: Float = 1
            for r in key.editor where r.isActive {
                let w = r.weight(hue: h, sat: s)
                guard w > 0 else { continue }
                dh += r.dHue * w
                satMul *= 1 + r.dSat / 100 * w
                lightMul *= 1 + r.dLight / 100 * 0.6 * w
            }
            h += dh
            s = min(max(s * satMul, 0), 1)
            v = max(v * lightMul, 0)
            let sk = key.skin
            if !sk.isNeutral {
                let w = ColorRange(hue: sk.hue, width: sk.width, soft: 0.8).weight(hue: h, sat: s)
                if w > 0 {
                    var dd = sk.hue - h
                    if dd > 180 { dd -= 360 } else if dd < -180 { dd += 360 }
                    h += dd * sk.hueAmount / 100 * w
                    s += (sk.sat - s) * sk.satAmount / 100 * w
                    v += (sk.light - v) * sk.lightAmount / 100 * w
                }
            }
            c = rgb(h, s, v)
        }

        if key.bw.enabled {
            let b = key.bw
            let (h, sat) = hue(of: c)
            // Only within 60° of each of the six color centers is affected. Low-saturation pixels move less.
            var adj: Float = 0
            for (center, sens) in [(0, b.red), (60, b.yellow), (120, b.green), (180, b.cyan), (240, b.blue), (300, b.magenta)] as [(Float, Float)] {
                var d = abs(h - center)
                if d > 180 { d = 360 - d }
                adj += max(0, 1 - d / 60) * sens / 100
            }
            var g = luma(c) * pow(2, adj * sat * 1.5)
            g = min(max(g, 0), 1)
            c = SIMD3(repeating: g)
            let ts = b.shadowTone, th = b.highlightTone
            if ts.amount != 0 { c += (1 - g) * (1 - g) * ts.amount * k * chroma(ts.hue) }
            if th.amount != 0 { c += g * g * th.amount * k * chroma(th.hue) }
        }
        return c.clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 1))
    }

    static func hsv(_ c: SIMD3<Float>) -> (Float, Float, Float) {
        let (h, s) = hue(of: c)
        return (h, s, max(c.x, c.y, c.z))
    }

    static func rgb(_ h0: Float, _ s: Float, _ v: Float) -> SIMD3<Float> {
        let h = ((h0.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 60
        let c = v * s, x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = v - c
        let r: SIMD3<Float>
        switch Int(h) {
        case 0: r = [c, x, 0]
        case 1: r = [x, c, 0]
        case 2: r = [0, c, x]
        case 3: r = [0, x, c]
        case 4: r = [x, 0, c]
        default: r = [c, 0, x]
        }
        return r + m
    }

    private static var lumaCache: (ToneCurve, [Float])?
    private static func lumaTable(_ curve: ToneCurve) -> [Float] {
        if let (c, t) = lumaCache, c == curve { return t }
        let t = curve.sample(256)
        lumaCache = (curve, t)
        return t
    }

    static func bake(_ key: Key) -> Data {
        let n = size
        var cube = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        // CIColorCube order: red changes fastest.
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let v = transform(key, SIMD3(Float(r), Float(g), Float(b)) / Float(n - 1))
                    cube[i] = v.x; cube[i + 1] = v.y; cube[i + 2] = v.z; cube[i + 3] = 1
                    i += 4
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
