import CoreImage

/// 컬러 밸런스 한 영역 (색 휠 하나). 색조 0~360, 양 0~1, 밝기 -1~1.
struct ColorShift: Equatable, Codable {
    var hue: Float = 0
    var amount: Float = 0
    var lightness: Float = 0
    var isNeutral: Bool { amount == 0 && lightness == 0 }
}

/// 흑백 변환. 색 여섯 개의 감도(-100~100)와 스플릿 톤.
struct BlackWhite: Equatable, Codable {
    var enabled = false
    var red: Float = 0, yellow: Float = 0, green: Float = 0
    var cyan: Float = 0, blue: Float = 0, magenta: Float = 0
    var shadowTone = ColorShift()
    var highlightTone = ColorShift()
}

/// 컬러 에디터 범위 하나. 가운데 색조에서 넓이의 절반까지는 100%, 그 밖으로 부드러움만큼 줄어든다.
struct ColorRange: Equatable, Codable {
    var name = ""
    var hue: Float
    var width: Float = 45
    var soft: Float = 0.6
    var dHue: Float = 0      // 색조 이동 -30~30°
    var dSat: Float = 0      // 채도 -100~100
    var dLight: Float = 0    // 밝기 -100~100
    /// 목록에서 체크를 끈 범위 (값은 두고 잠시 끈다)
    var off: Bool? = nil
    var isNeutral: Bool { dHue == 0 && dSat == 0 && dLight == 0 }
    var isActive: Bool { off != true && !isNeutral }

    /// 기본 컬러 에디터의 여덟 색.
    static let basic: [ColorRange] = [("빨강", 0), ("주황", 30), ("노랑", 60), ("초록", 120), ("청록", 180),
                                      ("파랑", 225), ("보라", 270), ("자홍", 315)]
        .map { ColorRange(name: $0.0, hue: $0.1) }

    /// 이 색(색조 h, 채도 s)에 걸리는 정도 0~1. 무채색에 가까우면 덜 걸린다 (회색이 물들지 않게).
    func weight(hue h: Float, sat s: Float) -> Float {
        var d = abs(h - hue).truncatingRemainder(dividingBy: 360)
        if d > 180 { d = 360 - d }
        let inner = width / 2, outer = inner + max(width * soft, 1)
        let hw: Float = d <= inner ? 1 : (d >= outer ? 0 : 1 - (d - inner) / (outer - inner))
        let t = min(max((s - 0.03) / 0.12, 0), 1)
        return hw * hw * (3 - 2 * hw) * (t * t * (3 - 2 * t))
    }
}

/// 스킨 톤 균일화: 고른 피부색 쪽으로 색조·채도·밝기의 흩어짐을 모은다.
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

/// 전역 색 연산을 3D LUT 하나로 굽는다. 컬러 밸런스, 흑백처럼 픽셀 하나만 보고 정해지는
/// 연산은 전부 여기 모은다. 32³ 격자면 한 번 굽는 데 수 ms, GPU에서는 삼선형 보간 한 번이다.
enum ColorLUT {
    static let size = 32

    struct Key: Equatable, Codable {
        var master = ColorShift(), shadow = ColorShift(), mid = ColorShift(), high = ColorShift()
        var bw = BlackWhite()
        /// 컬러 에디터: 앞 여덟은 기본 색, 그 뒤는 스포이트로 더한 범위 (고급, 최대 35개).
        var editor: [ColorRange] = ColorRange.basic
        var skin = SkinTone()
        /// 밝기(루마) 커브. 설정의 curves.luma를 현상 단계에서 넣어 준다.
        var luma = ToneCurve()
        var isNeutral: Bool {
            luma.isIdentity &&
            master.isNeutral && shadow.isNeutral && mid.isNeutral && high.isNeutral && !bw.enabled
                && !editor.contains(where: \.isActive) && skin.isNeutral
        }
    }

    private static var cache: (Key, Data)?

    static func apply(_ key: Key, to image: CIImage) -> CIImage {
        guard !key.isNeutral else { return image }
        let data: Data
        if let (k, d) = cache, k == key { data = d } else {
            data = bake(key)
            cache = (key, data)
        }
        // 화면 감마 공간에서 건다. 영역 가중치를 사람 눈 밝기 기준으로 나누기 위해서다.
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": size,
            "inputCubeData": data,
            "inputColorSpace": Render.displaySpace,
        ])
    }

    /// 색조 방향의 단위 색. 밝기 성분을 빼서 색만 옮기고 밝기는 그대로 둔다.
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
        let k: Float = 0.25   // 휠 끝까지 밀었을 때 색이 옮겨 가는 정도

        // 밝기 커브: 밝기만 곡선대로 옮기고 색 비율은 지킨다.
        if !key.luma.isIdentity {
            let table = lumaTable(key.luma)
            let y = min(max(luma(c), 0), 1)
            let f = y * Float(table.count - 1)
            let i = Int(f), j = min(i + 1, table.count - 1), t = f - Float(i)
            let ny = table[i] * (1 - t) + table[j] * t
            c = y > 1e-4 ? c * (ny / y) : SIMD3(repeating: ny)
        }

        // 컬러 밸런스: 섀도·미드톤·하이라이트 가중치는 합이 1이 되게 나눈다.
        let y = min(max(luma(c), 0), 1)
        let ws = (1 - y) * (1 - y), wh = y * y, wm = 1 - ws - wh
        for (w, s) in [(1, key.master), (ws, key.shadow), (wm, key.mid), (wh, key.high)] where !s.isNeutral {
            c += w * (s.amount * k * chroma(s.hue) + s.lightness * 0.2)
        }

        // 컬러 에디터·스킨 톤: HSV에서 옮긴다.
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
            // 색 여섯 개 중심에서 60° 안쪽만 영향을 받는다. 채도가 낮은 픽셀은 덜 움직인다.
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
        // CIColorCube 순서: 빨강이 가장 빨리 바뀐다.
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
