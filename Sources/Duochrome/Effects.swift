import CoreImage
import simd
import Foundation

/// 레이어 효과 (레이어에 차례로 쌓는 필터).
/// 조정 레이어면 아래까지 합친 결과에, 이미지·칠 레이어면 그 레이어 내용에 건다.
/// 반경·거리 값은 원본 픽셀 기준이고 미리보기 배율만큼 줄여 건다 (확대해도 같은 모습).
struct LayerEffect: Equatable, Codable, Identifiable {
    var id = UUID().uuidString
    var kind: String
    var enabled = true
    var params: [String: Double] = [:]
    /// 글자 값 (사용자 정의 필터의 계수, 참고 그림 파일 등)
    var text: String = ""

    init(kind: String) {
        self.kind = kind
        params = Effects.spec(kind)?.defaults ?? [:]
    }

    func value(_ key: String) -> Double {
        params[key] ?? Effects.spec(kind)?.params.first { $0.key == key }?.def ?? 0
    }
}

enum EffectCategory: String, CaseIterable {
    case blur = "흐림"
    case blurGallery = "흐림 갤러리"
    case sharpen = "선명 효과"
    case noise = "노이즈"
    case distort = "왜곡"
    case stylize = "스타일화"
    case render = "렌더"
    case pixelate = "픽셀화"
    case other = "기타"
    case adjust = "조정"
    case gallery = "필터 갤러리"
}

struct EffectParam {
    let key: String
    let title: String
    let range: ClosedRange<Double>
    let def: Double
    /// 원본 픽셀 거리 (미리보기 배율을 곱한다)
    var pixels = false
    var unit = ""
}

struct EffectSpec {
    let kind: String
    let title: String
    let category: EffectCategory
    let params: [EffectParam]
    /// 화면 감마(2.2)에서 거는가 (색·모양 필터는 대개 화면 값 기준이다)
    var gamma = false
    /// (그림, 값 읽기, 배율) → 결과. 결과는 원래 영역으로 자른다.
    let apply: (CIImage, (String) -> Double, CGFloat) -> CIImage

    var defaults: [String: Double] { Dictionary(uniqueKeysWithValues: params.map { ($0.key, $0.def) }) }
}

enum Effects {
    static func spec(_ kind: String) -> EffectSpec? { byKind[kind] }
    static let byKind: [String: EffectSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.kind, $0) })

    /// 효과를 차례로 건다
    static func apply(_ effects: [LayerEffect], _ img: CIImage, scale: CGFloat) -> CIImage {
        var o = img
        let e = img.extent
        for fx in effects where fx.enabled {
            guard let s = spec(fx.kind) else { continue }
            let get: (String) -> Double = { k in
                let v = fx.value(k)
                let p = s.params.first { $0.key == k }
                return p?.pixels == true ? v * Double(scale) : v
            }
            Thread.current.threadDictionary["duochrome.fxText"] = fx.text
            defer { Thread.current.threadDictionary["duochrome.fxText"] = nil }
            if s.gamma {
                let g = toGamma(o)
                o = fromGamma(s.apply(g, get, scale).cropped(to: e))
            } else {
                o = s.apply(o, get, scale).cropped(to: e)
            }
        }
        return o.cropped(to: e)
    }

    /// 지금 거는 효과의 글 값 (깊이 맵 파일 등). 효과를 거는 동안만 이 스레드에 둔다
    static var currentText: String { (Thread.current.threadDictionary["duochrome.fxText"] as? String) ?? "" }

    static let depthK = CIColorKernel(source: """
        kernel vec4 k(__sample d, float focus, float depth) { float v = clamp(abs(d.r - focus) / max(depth, 1e-3), 0.0, 1.0); return vec4(v, v, v, 1.0); }
        """)
    static let levelsK = CIColorKernel(source: """
        kernel vec4 k(__sample a, __sample b, __sample c, __sample d, __sample m) {
            float t = clamp(m.r, 0.0, 1.0) * 3.0;
            vec4 lo = t < 1.0 ? mix(a, b, t) : (t < 2.0 ? mix(b, c, t - 1.0) : mix(c, d, t - 2.0));
            return lo;
        }
        """)

    static func toGamma(_ i: CIImage) -> CIImage {
        i.applyingFilter("CIColorClamp").applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1 / 2.2])
    }
    static func fromGamma(_ i: CIImage) -> CIImage { i.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 2.2]) }

    // MARK: - 커널 (Core Image 커널 언어; 런타임에 컴파일)

    static let twirlK = CIWarpKernel(source: """
        kernel vec2 k(vec2 c, float radius, float angle) {
            vec2 d = destCoord() - c; float r = length(d);
            float t = r < radius ? angle * (1.0 - r / radius) * (1.0 - r / radius) : 0.0;
            float cs = cos(t), sn = sin(t);
            return c + vec2(d.x * cs - d.y * sn, d.x * sn + d.y * cs);
        }
        """)
    static let rippleK = CIWarpKernel(source: """
        kernel vec2 k(float amp, float wave, float kind) {
            vec2 p = destCoord();
            float ox = amp * sin(p.y * 6.2831853 / wave);
            float oy = kind > 0.5 ? amp * sin(p.x * 6.2831853 / wave) : 0.0;
            return p + vec2(ox, oy);
        }
        """)
    static let zigzagK = CIWarpKernel(source: """
        kernel vec2 k(vec2 c, float radius, float amp, float ridges) {
            vec2 d = destCoord() - c; float r = length(d);
            if (r >= radius || r < 0.001) return destCoord();
            float f = amp * sin(r / radius * ridges * 6.2831853) * (1.0 - r / radius);
            return destCoord() + d / r * f;
        }
        """)
    /// 극좌표: 직교 → 극 (mode 0) / 극 → 직교 (mode 1)
    static let polarK = CIWarpKernel(source: """
        kernel vec2 k(vec4 box, float mode) {
            vec2 p = destCoord() - box.xy; vec2 sz = box.zw; vec2 c = sz * 0.5;
            if (mode < 0.5) {
                vec2 d = p - c; float r = length(d) / (min(sz.x, sz.y) * 0.5);
                float a = (atan(d.x, -d.y) + 3.14159265) / 6.2831853;
                return box.xy + vec2(a * sz.x, (1.0 - r) * sz.y);
            } else {
                float a = p.x / sz.x * 6.2831853 - 3.14159265; float r = (1.0 - p.y / sz.y) * min(sz.x, sz.y) * 0.5;
                return box.xy + c + vec2(sin(a), -cos(a)) * r;
            }
        }
        """)
    /// 확산: 주변 무작위 자리에서 가져온다
    static let diffuseK = CIWarpKernel(source: """
        kernel vec2 k(float amount) {
            vec2 p = destCoord();
            float n1 = fract(sin(dot(floor(p), vec2(12.9898, 78.233))) * 43758.5453);
            float n2 = fract(sin(dot(floor(p), vec2(39.3468, 11.135))) * 24634.6345);
            return p + (vec2(n1, n2) - 0.5) * 2.0 * amount;
        }
        """)
    /// 회전 흐림: 가운데를 도는 호를 따라 평균
    static let spinK = CIKernel(source: """
        kernel vec4 k(sampler s, vec2 c, float angle) {
            vec2 d = destCoord() - c; vec4 acc = vec4(0.0); float n = 0.0;
            for (int i = -12; i <= 12; i++) {
                float t = angle * float(i) / 12.0; float cs = cos(t), sn = sin(t);
                vec2 q = c + vec2(d.x * cs - d.y * sn, d.x * sn + d.y * cs);
                acc += sample(s, samplerTransform(s, q)); n += 1.0;
            }
            return acc / n;
        }
        """)
    /// 쿠와하라 (유화): 네 사분면 중 분산이 가장 작은 쪽의 평균
    static let kuwaharaK = CIKernel(source: """
        kernel vec4 k(sampler s, float r) {
            vec2 p = destCoord(); float R = clamp(floor(r), 1.0, 6.0);
            vec3 m0 = vec3(0.0), m1 = vec3(0.0), m2 = vec3(0.0), m3 = vec3(0.0);
            vec3 v0 = vec3(0.0), v1 = vec3(0.0), v2 = vec3(0.0), v3 = vec3(0.0);
            for (float j = -6.0; j <= 6.0; j += 1.0) {
                for (float i = -6.0; i <= 6.0; i += 1.0) {
                    if (abs(i) <= R && abs(j) <= R) {
                        vec3 c = sample(s, samplerTransform(s, p + vec2(i, j))).rgb;
                        if (i <= 0.0 && j <= 0.0) { m0 += c; v0 += c * c; }
                        if (i >= 0.0 && j <= 0.0) { m1 += c; v1 += c * c; }
                        if (i <= 0.0 && j >= 0.0) { m2 += c; v2 += c * c; }
                        if (i >= 0.0 && j >= 0.0) { m3 += c; v3 += c * c; }
                    }
                }
            }
            float n = (R + 1.0) * (R + 1.0);
            m0 /= n; m1 /= n; m2 /= n; m3 /= n;
            vec3 s0 = abs(v0 / n - m0 * m0), s1 = abs(v1 / n - m1 * m1), s2 = abs(v2 / n - m2 * m2), s3 = abs(v3 / n - m3 * m3);
            float a0 = s0.r + s0.g + s0.b, a1 = s1.r + s1.g + s1.b, a2 = s2.r + s2.g + s2.b, a3 = s3.r + s3.g + s3.b;
            vec3 outc = m0; float best = a0;
            if (a1 < best) { best = a1; outc = m1; }
            if (a2 < best) { best = a2; outc = m2; }
            if (a3 < best) { best = a3; outc = m3; }
            return vec4(outc, sample(s, samplerCoord(s)).a);
        }
        """)
    /// 표면 흐림 (양방향 필터): 가까우면서 색이 비슷한 픽셀만 평균
    static let bilateralK = CIKernel(source: """
        kernel vec4 k(sampler s, float radius, float threshold) {
            vec2 p = destCoord(); vec4 c0 = sample(s, samplerCoord(s));
            vec4 acc = vec4(0.0); float wsum = 0.0; float step = max(radius / 6.0, 1.0);
            for (int j = -6; j <= 6; j++) for (int i = -6; i <= 6; i++) {
                vec2 o = vec2(float(i), float(j)) * step;
                vec4 c = sample(s, samplerTransform(s, p + o));
                float dc = length(c.rgb - c0.rgb);
                float w = exp(-dot(o, o) / (2.0 * radius * radius)) * exp(-dc * dc / (2.0 * threshold * threshold));
                acc += c * w; wsum += w;
            }
            return acc / max(wsum, 1e-5);
        }
        """)
    /// 선택 색상: 색 무리별(빨강·노랑·초록·녹청·파랑·자홍·흰·중간·검정) 청록·자홍·노랑·검정 가감 (상대 방식)
    static let selectiveK = CIColorKernel(source: """
        kernel vec4 k(__sample s, vec4 red, vec4 yellow, vec4 green, vec4 cyan, vec4 blue, vec4 magenta, vec4 whites, vec4 neutrals, vec4 blacks) {
            vec3 c = clamp(s.rgb, 0.0, 1.0);
            float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
            float chroma = mx - mn;
            float h = 0.0;
            if (chroma > 0.0001) {
                if (mx == c.r) h = mod((c.g - c.b) / chroma, 6.0);
                else if (mx == c.g) h = (c.b - c.r) / chroma + 2.0;
                else h = (c.r - c.g) / chroma + 4.0;
            }
            float hd = h * 60.0;
            float wr = max(0.0, 1.0 - min(abs(hd - 0.0), abs(hd - 360.0)) / 60.0);
            float wy = max(0.0, 1.0 - abs(hd - 60.0) / 60.0);
            float wg = max(0.0, 1.0 - abs(hd - 120.0) / 60.0);
            float wc = max(0.0, 1.0 - abs(hd - 180.0) / 60.0);
            float wb = max(0.0, 1.0 - abs(hd - 240.0) / 60.0);
            float wm = max(0.0, 1.0 - abs(hd - 300.0) / 60.0);
            vec4 adj = (red * wr + yellow * wy + green * wg + cyan * wc + blue * wb + magenta * wm) * chroma;
            float l = (mx + mn) * 0.5;
            adj += whites * clamp((l - 0.5) * 2.0, 0.0, 1.0) * (1.0 - chroma);
            adj += blacks * clamp((0.5 - l) * 2.0, 0.0, 1.0) * (1.0 - chroma);
            adj += neutrals * (1.0 - abs(l - 0.5) * 2.0) * (1.0 - chroma);
            vec3 cmy = 1.0 - c;
            cmy = clamp(cmy + cmy * adj.xyz + adj.w * (1.0 - cmy) * 0.0, 0.0, 1.0);
            vec3 outc = 1.0 - cmy;
            outc = outc * (1.0 - adj.w);
            return vec4(outc, s.a);
        }
        """)
    /// 먼지와 스크래치: 중간값과 차이가 한계값보다 큰 픽셀만 바꾼다
    static let thresholdMixK = CIColorKernel(source: """
        kernel vec4 k(__sample orig, __sample med, float t) {
            return length(orig.rgb - med.rgb) > t ? med : orig;
        }
        """)
    static let divideK = CIColorKernel(source: """
        kernel vec4 k(__sample a, __sample b) { return vec4(a.rgb / max(b.rgb, vec3(0.002)), a.a); }
        """)
    static let multiplyK = CIColorKernel(source: """
        kernel vec4 k(__sample a, __sample b) { return vec4(a.rgb * b.rgb, a.a); }
        """)
    /// 바람: 밝은 가장자리를 한쪽으로 끈다 (이동 흐림한 가장자리를 원본에 밝게 합친다)
    static let lightenK = CIColorKernel(source: """
        kernel vec4 k(__sample a, __sample b, float amt) { return vec4(max(a.rgb, mix(a.rgb, b.rgb, amt)), a.a); }
        """)
    /// 메조틴트: 무작위 문턱으로 점을 찍는다
    static let mezzoK = CIColorKernel(source: """
        kernel vec4 k(__sample s, __sample n) { return vec4(step(n.rgb, s.rgb), s.a); }
        """)

    // MARK: - 도움 함수

    static func center(_ img: CIImage, _ v: (String) -> Double) -> CIVector {
        let e = img.extent
        return CIVector(x: e.minX + e.width * CGFloat(v("cx")), y: e.minY + e.height * CGFloat(v("cy")))
    }

    static func warp(_ k: CIWarpKernel?, _ img: CIImage, pad: CGFloat, _ args: [Any]) -> CIImage {
        guard let k else { return img }
        let src = img.clampedToExtent()
        return k.apply(extent: img.extent, roiCallback: { _, r in r.insetBy(dx: -pad, dy: -pad) }, image: src, arguments: args) ?? img
    }

    static func general(_ k: CIKernel?, _ img: CIImage, pad: CGFloat, _ args: [Any]) -> CIImage {
        guard let k else { return img }
        let src = img.clampedToExtent()
        return k.apply(extent: img.extent, roiCallback: { _, r in r.insetBy(dx: -pad, dy: -pad) }, arguments: [src] + args) ?? img
    }

    static func gray(_ i: CIImage) -> CIImage { i.applyingFilter("CIPhotoEffectMono") }

    /// 구름 (프랙탈 잡음): 무작위 잡음을 여러 크기로 흐려 더한다
    static func clouds(_ e: CGRect, scale: CGFloat, seed: Double) -> CIImage {
        var acc: CIImage?
        var amp: CGFloat = 0.5
        for oct in 0..<5 {
            let size = max(256 * scale / pow(2, CGFloat(oct)), 2)
            let n = CIFilter(name: "CIRandomGenerator")!.outputImage!
                .transformed(by: .init(translationX: CGFloat(seed * 97) + CGFloat(oct) * 131, y: CGFloat(seed * 53)))
                .applyingFilter("CIPhotoEffectMono")
                .transformed(by: .init(scaleX: size / 8, y: size / 8))
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: size / 3])
                .cropped(to: e)
            let scaled = n.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: amp, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: amp, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: amp, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            acc = acc.map { scaled.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? scaled
            amp /= 2
        }
        return (acc ?? CIImage(color: .gray)).cropped(to: e)
    }

    /// 흐림 강도 마스크로 흐린다 (흐림 갤러리)
    static func variableBlur(_ img: CIImage, mask: CIImage, radius: CGFloat) -> CIImage {
        img.clampedToExtent().applyingFilter("CIMaskedVariableBlur", parameters: [
            "inputMask": mask.clampedToExtent(), kCIInputRadiusKey: max(radius, 0.1),
        ]).cropped(to: img.extent)
    }

    static func constant(_ v: CGFloat, _ e: CGRect) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v)).cropped(to: e)
    }

    // MARK: - 효과 목록

    static let all: [EffectSpec] = blurs + gallery + sharpens + noises + distorts + stylizes + renders + pixelates + others + adjusts + artistic + galleryFilters

    static let blurs: [EffectSpec] = [
        EffectSpec(kind: "gaussian", title: "가우시안 흐림", category: .blur,
                   params: [EffectParam(key: "radius", title: "반경", range: 0...250, def: 8, pixels: true, unit: "px")]) { i, v, _ in
            i.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: v("radius")])
        },
        EffectSpec(kind: "box", title: "상자 흐림", category: .blur,
                   params: [EffectParam(key: "radius", title: "반경", range: 1...250, def: 10, pixels: true, unit: "px")]) { i, v, _ in
            i.clampedToExtent().applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: max(v("radius"), 1)])
        },
        EffectSpec(kind: "motion", title: "동작 흐림", category: .blur,
                   params: [EffectParam(key: "distance", title: "거리", range: 1...500, def: 30, pixels: true, unit: "px"),
                            EffectParam(key: "angle", title: "각도", range: -180...180, def: 0, unit: "°")]) { i, v, _ in
            i.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [
                kCIInputRadiusKey: max(v("distance"), 0.5), kCIInputAngleKey: v("angle") * .pi / 180])
        },
        EffectSpec(kind: "radialZoom", title: "방사형 흐림 (확대)", category: .blur,
                   params: [EffectParam(key: "amount", title: "양", range: 1...200, def: 30, pixels: true),
                            EffectParam(key: "cx", title: "가운데 가로", range: 0...1, def: 0.5),
                            EffectParam(key: "cy", title: "가운데 세로", range: 0...1, def: 0.5)]) { i, v, _ in
            i.clampedToExtent().applyingFilter("CIZoomBlur", parameters: [kCIInputCenterKey: center(i, v), "inputAmount": v("amount")])
        },
        EffectSpec(kind: "radialSpin", title: "방사형 흐림 (회전)", category: .blur,
                   params: [EffectParam(key: "angle", title: "각도", range: 0...60, def: 10, unit: "°"),
                            EffectParam(key: "cx", title: "가운데 가로", range: 0...1, def: 0.5),
                            EffectParam(key: "cy", title: "가운데 세로", range: 0...1, def: 0.5)]) { i, v, _ in
            let r = hypot(i.extent.width, i.extent.height)
            return general(spinK, i, pad: r, [center(i, v), v("angle") * .pi / 180 / 2])
        },
        EffectSpec(kind: "surface", title: "표면 흐림", category: .blur,
                   params: [EffectParam(key: "radius", title: "반경", range: 1...60, def: 8, pixels: true, unit: "px"),
                            EffectParam(key: "threshold", title: "한계값", range: 1...100, def: 15)]) { i, v, _ in
            general(bilateralK, i, pad: v("radius") * 2, [max(v("radius"), 1), v("threshold") / 255 * 2])
        },
        EffectSpec(kind: "smartBlur", title: "고급 흐림", category: .blur,
                   params: [EffectParam(key: "radius", title: "반경", range: 1...60, def: 4, pixels: true, unit: "px"),
                            EffectParam(key: "threshold", title: "한계값", range: 1...100, def: 25)]) { i, v, _ in
            general(bilateralK, i, pad: v("radius") * 2, [max(v("radius"), 1), v("threshold") / 255 * 3])
        },
        EffectSpec(kind: "average", title: "평균", category: .blur, params: []) { i, _, _ in
            i.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: i.extent)])
                .clampedToExtent()
        },
        EffectSpec(kind: "lensBlur", title: "렌즈 흐림 (깊이)", category: .blur,
                   params: [EffectParam(key: "radius", title: "반경", range: 0...80, def: 15, pixels: true, unit: "px"),
                            EffectParam(key: "ring", title: "빛망울 테두리", range: 0...1, def: 0.2),
                            EffectParam(key: "focus", title: "초점 (세로: 위 0~아래 1 · 깊이 맵: 가까움 0~멂 1)", range: 0...1, def: 0.6),
                            EffectParam(key: "depth", title: "초점 깊이", range: 0.02...1, def: 0.25),
                            EffectParam(key: "source", title: "깊이 (0 세로 위치 · 1 깊이 맵)", range: 0...1, def: 0)]) { i, v, _ in
            let e = i.extent
            var mask: CIImage
            let text = Effects.currentText
            if v("source") >= 0.5, text.hasPrefix("depth:"), let d = Layers.sourceImage(String(text.dropFirst(6))), d.extent.width > 0 {
                // 깊이 맵(0 가까움 ~ 1 멂)을 이 그림에 맞춰 늘리고, 초점 깊이에서 멀수록 1
                let fit = d.transformed(by: .init(scaleX: e.width / d.extent.width, y: e.height / d.extent.height))
                    .transformed(by: .init(translationX: e.minX - d.extent.minX * e.width / d.extent.width, y: e.minY - d.extent.minY * e.height / d.extent.height))
                    .clampedToExtent().cropped(to: e)
                mask = depthK?.apply(extent: e, arguments: [fit, Float(v("focus")), Float(v("depth"))]) ?? fit
            } else {
                // 깊이 맵이 없으면 세로 위치 (아래가 가깝다)
                let f = e.minY + e.height * CGFloat(1 - v("focus")), d = e.height * CGFloat(v("depth"))
                let up = CIFilter(name: "CILinearGradient", parameters: [
                    "inputPoint0": CIVector(x: 0, y: f), "inputColor0": CIColor.black,
                    "inputPoint1": CIVector(x: 0, y: f + d), "inputColor1": CIColor.white])!.outputImage!.cropped(to: e)
                let down = CIFilter(name: "CILinearGradient", parameters: [
                    "inputPoint0": CIVector(x: 0, y: f), "inputColor0": CIColor.black,
                    "inputPoint1": CIVector(x: 0, y: f - d), "inputColor1": CIColor.white])!.outputImage!.cropped(to: e)
                mask = up.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: down])
            }
            // 흐림 세 단계를 깊이 차이로 섞는다 (먼 곳일수록 반경이 커진다)
            let r = max(v("radius"), 0.1)
            func bokeh(_ k: Double) -> CIImage {
                i.clampedToExtent().applyingFilter("CIBokehBlur", parameters: [
                    kCIInputRadiusKey: max(r * k, 0.1), "inputRingAmount": v("ring"), "inputSoftness": 1]).cropped(to: e)
            }
            return levelsK?.apply(extent: e, arguments: [i, bokeh(1.0 / 3), bokeh(2.0 / 3), bokeh(1), mask]) ?? i
        },
    ]

    static let gallery: [EffectSpec] = [
        EffectSpec(kind: "fieldBlur", title: "필드 흐림", category: .blurGallery,
                   params: [EffectParam(key: "radius", title: "흐림", range: 0...150, def: 15, pixels: true, unit: "px")]) { i, v, _ in
            i.clampedToExtent().applyingFilter("CIBokehBlur", parameters: [kCIInputRadiusKey: max(v("radius"), 0.1),
                                                                            "inputRingAmount": 0, "inputSoftness": 1])
        },
        EffectSpec(kind: "irisBlur", title: "조리개 흐림", category: .blurGallery,
                   params: [EffectParam(key: "radius", title: "흐림", range: 0...150, def: 20, pixels: true, unit: "px"),
                            EffectParam(key: "cx", title: "가운데 가로", range: 0...1, def: 0.5),
                            EffectParam(key: "cy", title: "가운데 세로", range: 0...1, def: 0.5),
                            EffectParam(key: "size", title: "선명한 원 크기", range: 0.05...1, def: 0.3),
                            EffectParam(key: "feather", title: "번짐 폭", range: 0.02...1, def: 0.3)]) { i, v, _ in
            let e = i.extent, m = min(e.width, e.height)
            let r0 = m * CGFloat(v("size")) / 2
            let mask = CIFilter(name: "CIRadialGradient", parameters: [
                kCIInputCenterKey: center(i, v), "inputRadius0": r0, "inputRadius1": r0 + m * CGFloat(v("feather")),
                "inputColor0": CIColor.black, "inputColor1": CIColor.white])!.outputImage!.cropped(to: e)
            return variableBlur(i, mask: mask, radius: v("radius"))
        },
        EffectSpec(kind: "tiltShift", title: "틸트-시프트", category: .blurGallery,
                   params: [EffectParam(key: "radius", title: "흐림", range: 0...150, def: 20, pixels: true, unit: "px"),
                            EffectParam(key: "cy", title: "선명한 띠 세로 위치", range: 0...1, def: 0.5),
                            EffectParam(key: "band", title: "선명한 띠 폭", range: 0.01...0.8, def: 0.15),
                            EffectParam(key: "feather", title: "번짐 폭", range: 0.02...1, def: 0.25)]) { i, v, _ in
            let e = i.extent
            let c = e.minY + e.height * CGFloat(v("cy")), b = e.height * CGFloat(v("band")) / 2, f = e.height * CGFloat(v("feather"))
            func grad(_ y0: CGFloat, _ y1: CGFloat) -> CIImage {
                CIFilter(name: "CILinearGradient", parameters: [
                    "inputPoint0": CIVector(x: 0, y: y0), "inputColor0": CIColor.black,
                    "inputPoint1": CIVector(x: 0, y: y1), "inputColor1": CIColor.white])!.outputImage!.cropped(to: e)
            }
            let mask = grad(c + b, c + b + f).applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: grad(c - b, c - b - f)])
            return variableBlur(i, mask: mask, radius: v("radius"))
        },
        EffectSpec(kind: "pathBlur", title: "경로 흐림", category: .blurGallery,
                   params: [EffectParam(key: "distance", title: "거리", range: 1...400, def: 40, pixels: true, unit: "px"),
                            EffectParam(key: "angle", title: "처음 방향", range: -180...180, def: 0, unit: "°"),
                            EffectParam(key: "curve", title: "휘는 정도", range: -90...90, def: 20, unit: "°")]) { i, v, _ in
            // 두 방향 동작 흐림을 위아래로 섞어 휘는 경로를 근사한다
            let e = i.extent
            let a0 = v("angle") * .pi / 180, a1 = (v("angle") + v("curve")) * .pi / 180
            let m0 = i.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: max(v("distance"), 0.5), kCIInputAngleKey: a0]).cropped(to: e)
            let m1 = i.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: max(v("distance"), 0.5), kCIInputAngleKey: a1]).cropped(to: e)
            let mask = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: e.minY), "inputColor0": CIColor.black,
                "inputPoint1": CIVector(x: 0, y: e.maxY), "inputColor1": CIColor.white])!.outputImage!.cropped(to: e)
            return m1.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: m0, "inputMaskImage": mask])
        },
        EffectSpec(kind: "spinBlur", title: "회전 흐림", category: .blurGallery,
                   params: [EffectParam(key: "angle", title: "흐림 각도", range: 0...90, def: 15, unit: "°"),
                            EffectParam(key: "cx", title: "가운데 가로", range: 0...1, def: 0.5),
                            EffectParam(key: "cy", title: "가운데 세로", range: 0...1, def: 0.5),
                            EffectParam(key: "size", title: "도는 원 크기", range: 0.05...1.5, def: 0.5)]) { i, v, _ in
            let e = i.extent, m = min(e.width, e.height)
            let spun = general(spinK, i, pad: hypot(e.width, e.height), [center(i, v), v("angle") * .pi / 180 / 2]).cropped(to: e)
            let r = m * CGFloat(v("size")) / 2
            let mask = CIFilter(name: "CIRadialGradient", parameters: [
                kCIInputCenterKey: center(i, v), "inputRadius0": r * 0.85, "inputRadius1": r,
                "inputColor0": CIColor.white, "inputColor1": CIColor.black])!.outputImage!.cropped(to: e)
            return spun.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: i, "inputMaskImage": mask])
        },
    ]

    static let sharpens: [EffectSpec] = [
        EffectSpec(kind: "unsharp", title: "언샤프 마스크", category: .sharpen,
                   params: [EffectParam(key: "amount", title: "양", range: 0...500, def: 100, unit: "%"),
                            EffectParam(key: "radius", title: "반경", range: 0.1...50, def: 1.5, pixels: true, unit: "px"),
                            EffectParam(key: "threshold", title: "한계값", range: 0...255, def: 0)]) { i, v, _ in
            let sharp = i.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: max(v("radius"), 0.3), kCIInputIntensityKey: v("amount") / 100]).cropped(to: i.extent)
            guard v("threshold") > 0, let k = thresholdMixK else { return sharp }
            return k.apply(extent: i.extent, arguments: [i, sharp, v("threshold") / 255]) ?? sharp
        },
        EffectSpec(kind: "smartSharpen", title: "고급 선명 효과", category: .sharpen,
                   params: [EffectParam(key: "amount", title: "양", range: 0...500, def: 150, unit: "%"),
                            EffectParam(key: "radius", title: "반경", range: 0.1...20, def: 1, pixels: true, unit: "px"),
                            EffectParam(key: "noise", title: "노이즈 줄이기", range: 0...100, def: 10, unit: "%")]) { i, v, _ in
            // 밝기만 선명하게 (색 가장자리 번짐이 없다), 먼저 잔 노이즈를 누른다
            var o = i
            if v("noise") > 0 { o = o.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": v("noise") / 1000, "inputSharpness": 0.4]) }
            return o.clampedToExtent().applyingFilter("CISharpenLuminance", parameters: [
                "inputSharpness": v("amount") / 100, kCIInputRadiusKey: max(v("radius"), 0.3)])
        },
        EffectSpec(kind: "shakeReduction", title: "흔들림 감소", category: .sharpen,
                   params: [EffectParam(key: "length", title: "흔들린 거리", range: 1...60, def: 8, pixels: true, unit: "px"),
                            EffectParam(key: "angle", title: "흔들린 방향", range: -90...90, def: 0, unit: "°"),
                            EffectParam(key: "iterations", title: "반복", range: 1...20, def: 8)]) { i, v, _ in
            // 리처드슨-루시 역합성곱: 흔들림을 직선 동작 흐림으로 보고 되풀이해 되돌린다
            guard let dk = divideK, let mk = multiplyK else { return i }
            let e = i.extent
            func psf(_ x: CIImage) -> CIImage {
                x.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [
                    kCIInputRadiusKey: max(v("length") / 2, 0.5), kCIInputAngleKey: v("angle") * .pi / 180]).cropped(to: e)
            }
            let obs = i.applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0.001, y: 0.001, z: 0.001, w: 0)])
            var est = obs
            for _ in 0..<Int(v("iterations")) {
                guard let ratio = dk.apply(extent: e, arguments: [obs, psf(est)]),
                      let next = mk.apply(extent: e, arguments: [est, psf(ratio)]) else { break }
                est = next
            }
            return est
        },
    ]

    static let noises: [EffectSpec] = [
        EffectSpec(kind: "addNoise", title: "노이즈 추가", category: .noise,
                   params: [EffectParam(key: "amount", title: "양", range: 0...100, def: 12, unit: "%"),
                            EffectParam(key: "mono", title: "흑백 (1 켬)", range: 0...1, def: 1)]) { i, v, s in
            Develop.grain(i, amount: Float(v("amount")), size: 10, scale: s, type: v("mono") >= 0.5 ? 3 : 1)
        },
        EffectSpec(kind: "reduceNoise", title: "노이즈 감소", category: .noise,
                   params: [EffectParam(key: "strength", title: "강도", range: 0...100, def: 40),
                            EffectParam(key: "detail", title: "세부 유지", range: 0...100, def: 40)]) { i, v, _ in
            i.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": v("strength") / 1000, "inputSharpness": v("detail") / 50])
        },
        EffectSpec(kind: "dustScratches", title: "먼지와 스크래치", category: .noise,
                   params: [EffectParam(key: "radius", title: "반경", range: 1...5, def: 2),
                            EffectParam(key: "threshold", title: "한계값", range: 0...255, def: 20)]) { i, v, _ in
            var med = i
            for _ in 0..<Int(v("radius")) { med = med.applyingFilter("CIMedianFilter").cropped(to: i.extent) }
            guard let k = thresholdMixK else { return med }
            return k.apply(extent: i.extent, arguments: [i, med, v("threshold") / 255]) ?? med
        },
        EffectSpec(kind: "median", title: "중간값", category: .noise,
                   params: [EffectParam(key: "passes", title: "반복", range: 1...8, def: 2)]) { i, v, _ in
            var o = i
            for _ in 0..<Int(v("passes")) { o = o.applyingFilter("CIMedianFilter").cropped(to: i.extent) }
            return o
        },
        EffectSpec(kind: "despeckle", title: "반점 제거", category: .noise, params: []) { i, _, _ in
            i.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.02, "inputSharpness": 0.9])
        },
    ]

    static let distorts: [EffectSpec] = [
        EffectSpec(kind: "spherize", title: "구형화", category: .distort,
                   params: [EffectParam(key: "amount", title: "양", range: -1...1, def: 0.6),
                            EffectParam(key: "size", title: "크기", range: 0.1...1.5, def: 0.9)]) { i, v, _ in
            let e = i.extent
            return i.clampedToExtent().applyingFilter("CIBumpDistortion", parameters: [
                kCIInputCenterKey: CIVector(x: e.midX, y: e.midY), kCIInputRadiusKey: min(e.width, e.height) * CGFloat(v("size")) / 2,
                kCIInputScaleKey: v("amount")])
        },
        EffectSpec(kind: "twirl", title: "돌리기", category: .distort,
                   params: [EffectParam(key: "angle", title: "각도", range: -999...999, def: 200, unit: "°"),
                            EffectParam(key: "size", title: "크기", range: 0.1...1.5, def: 0.8)]) { i, v, _ in
            let e = i.extent, r = min(e.width, e.height) * CGFloat(v("size")) / 2
            return warp(twirlK, i, pad: r, [CIVector(x: e.midX, y: e.midY), r, v("angle") * .pi / 180])
        },
        EffectSpec(kind: "pinch", title: "핀치", category: .distort,
                   params: [EffectParam(key: "amount", title: "양", range: -100...100, def: 50, unit: "%")]) { i, v, _ in
            let e = i.extent
            let amt = v("amount") / 100
            if amt >= 0 {
                return i.clampedToExtent().applyingFilter("CIPinchDistortion", parameters: [
                    kCIInputCenterKey: CIVector(x: e.midX, y: e.midY), kCIInputRadiusKey: min(e.width, e.height) / 2, kCIInputScaleKey: amt])
            }
            return i.clampedToExtent().applyingFilter("CIBumpDistortion", parameters: [
                kCIInputCenterKey: CIVector(x: e.midX, y: e.midY), kCIInputRadiusKey: min(e.width, e.height) / 2, kCIInputScaleKey: -amt])
        },
        EffectSpec(kind: "ripple", title: "잔물결", category: .distort,
                   params: [EffectParam(key: "amp", title: "크기", range: 0...100, def: 8, pixels: true, unit: "px"),
                            EffectParam(key: "wave", title: "파장", range: 4...600, def: 60, pixels: true, unit: "px")]) { i, v, _ in
            warp(rippleK, i, pad: v("amp") + 2, [v("amp"), max(v("wave"), 1), 1.0])
        },
        EffectSpec(kind: "wave", title: "파형", category: .distort,
                   params: [EffectParam(key: "amp", title: "진폭", range: 0...200, def: 20, pixels: true, unit: "px"),
                            EffectParam(key: "wave", title: "파장", range: 4...1200, def: 200, pixels: true, unit: "px")]) { i, v, _ in
            warp(rippleK, i, pad: v("amp") + 2, [v("amp"), max(v("wave"), 1), 0.0])
        },
        EffectSpec(kind: "zigzag", title: "지그재그", category: .distort,
                   params: [EffectParam(key: "amp", title: "양", range: 0...100, def: 20, pixels: true, unit: "px"),
                            EffectParam(key: "ridges", title: "물결 수", range: 1...20, def: 5),
                            EffectParam(key: "size", title: "크기", range: 0.1...1.5, def: 0.9)]) { i, v, _ in
            let e = i.extent, r = min(e.width, e.height) * CGFloat(v("size")) / 2
            return warp(zigzagK, i, pad: v("amp") + 2, [CIVector(x: e.midX, y: e.midY), r, v("amp"), v("ridges")])
        },
        EffectSpec(kind: "polar", title: "극좌표", category: .distort,
                   params: [EffectParam(key: "mode", title: "직교→극 0 / 극→직교 1", range: 0...1, def: 0)]) { i, v, _ in
            let e = i.extent
            return warp(polarK, i, pad: max(e.width, e.height), [CIVector(cgRect: e), v("mode") >= 0.5 ? 1.0 : 0.0])
        },
        EffectSpec(kind: "glass", title: "유리", category: .distort,
                   params: [EffectParam(key: "scale", title: "왜곡", range: 0...400, def: 80, pixels: true)]) { i, v, s in
            let tex = clouds(i.extent, scale: s, seed: 3)
            return i.clampedToExtent().applyingFilter("CIGlassDistortion", parameters: [
                "inputTexture": tex, kCIInputCenterKey: CIVector(x: i.extent.midX, y: i.extent.midY), kCIInputScaleKey: v("scale")])
        },
        EffectSpec(kind: "displace", title: "변위 (구름 무늬)", category: .distort,
                   params: [EffectParam(key: "scale", title: "양", range: 0...400, def: 40, pixels: true)]) { i, v, s in
            let tex = clouds(i.extent, scale: s, seed: 7)
            return i.clampedToExtent().applyingFilter("CIDisplacementDistortion", parameters: [
                "inputDisplacementImage": tex, kCIInputScaleKey: v("scale")])
        },
    ]

    static let stylizes: [EffectSpec] = [
        EffectSpec(kind: "findEdges", title: "가장자리 찾기", category: .stylize, params: [], gamma: true) { i, _, _ in
            i.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 3]).applyingFilter("CIColorInvert")
        },
        EffectSpec(kind: "emboss", title: "엠보스", category: .stylize,
                   params: [EffectParam(key: "angle", title: "각도", range: -180...180, def: 135, unit: "°"),
                            EffectParam(key: "amount", title: "양", range: 1...500, def: 100, unit: "%")], gamma: true) { i, v, _ in
            let a = v("angle") * .pi / 180, k = CGFloat(v("amount") / 100)
            let dx = CGFloat(cos(a)), dy = CGFloat(sin(a))
            let w: [CGFloat] = [-(dx + dy), -dy, dx - dy, -dx, 0, dx, -dx + dy, dy, dx + dy].map { $0 * k }
            return gray(i).clampedToExtent().applyingFilter("CIConvolution3X3", parameters: [
                "inputWeights": CIVector(values: w, count: 9), "inputBias": 0.5])
        },
        EffectSpec(kind: "diffuse", title: "확산", category: .stylize,
                   params: [EffectParam(key: "amount", title: "양", range: 0...20, def: 3, pixels: true, unit: "px")]) { i, v, _ in
            warp(diffuseK, i, pad: v("amount") + 2, [v("amount")])
        },
        EffectSpec(kind: "wind", title: "바람", category: .stylize,
                   params: [EffectParam(key: "distance", title: "거리", range: 1...300, def: 40, pixels: true, unit: "px"),
                            EffectParam(key: "direction", title: "방향 (0 오른쪽 / 180 왼쪽)", range: 0...180, def: 0, unit: "°")], gamma: true) { i, v, _ in
            let e = i.extent
            let edges = i.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 4]).cropped(to: e)
            let streak = edges.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [
                kCIInputRadiusKey: max(v("distance"), 0.5), kCIInputAngleKey: v("direction") * .pi / 180])
                .transformed(by: .init(translationX: CGFloat(v("distance")) * (v("direction") < 90 ? 0.5 : -0.5), y: 0)).cropped(to: e)
            guard let k = lightenK else { return i }
            return k.apply(extent: e, arguments: [i, i.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: streak]), 0.8]) ?? i
        },
        EffectSpec(kind: "oilPaint", title: "유화", category: .stylize,
                   params: [EffectParam(key: "radius", title: "붓 크기", range: 1...6, def: 4)], gamma: true) { i, v, s in
            // 커널 반경은 픽셀 고정(최대 6)이라, 크게 칠하려면 줄여서 걸고 다시 키운다
            let k = max(min(s * 1.0, 1), 0.25)
            let small = i.transformed(by: .init(scaleX: k, y: k))
            let painted = general(kuwaharaK, small, pad: 7, [v("radius")])
            return painted.transformed(by: .init(scaleX: 1 / k, y: 1 / k))
        },
        EffectSpec(kind: "solarize", title: "솔라리즈", category: .stylize, params: [], gamma: true) { i, _, _ in
            let inv = i.applyingFilter("CIColorInvert")
            return i.applyingFilter("CIDarkenBlendMode", parameters: [kCIInputBackgroundImageKey: inv])
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 2])
        },
        EffectSpec(kind: "traceContour", title: "윤곽선", category: .stylize,
                   params: [EffectParam(key: "threshold", title: "문턱", range: 0...1, def: 0.1)], gamma: true) { i, v, _ in
            i.applyingFilter("CILineOverlay", parameters: ["inputThreshold": v("threshold"), "inputEdgeIntensity": 1])
                .applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: CIImage(color: .white).cropped(to: i.extent)])
        },
    ]

    static let renders: [EffectSpec] = [
        EffectSpec(kind: "clouds", title: "구름", category: .render,
                   params: [EffectParam(key: "mix", title: "섞기", range: 0...1, def: 1),
                            EffectParam(key: "seed", title: "무늬 번호", range: 0...100, def: 1)], gamma: true) { i, v, s in
            let c = clouds(i.extent, scale: s, seed: v("seed")).applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.6])
            return c.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: c, kCIInputImageKey: i, kCIInputTimeKey: v("mix")])
        },
        EffectSpec(kind: "fibers", title: "섬유", category: .render,
                   params: [EffectParam(key: "mix", title: "섞기", range: 0...1, def: 1),
                            EffectParam(key: "length", title: "길이", range: 4...200, def: 40, pixels: true)], gamma: true) { i, v, _ in
            let e = i.extent
            let n = CIFilter(name: "CIRandomGenerator")!.outputImage!.applyingFilter("CIPhotoEffectMono")
                .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: v("length"), kCIInputAngleKey: CGFloat.pi / 2])
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 3]).cropped(to: e)
            return n.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: n, kCIInputImageKey: i, kCIInputTimeKey: v("mix")])
        },
        EffectSpec(kind: "lighting", title: "조명 효과 (스포트라이트)", category: .render,
                   params: [EffectParam(key: "cx", title: "빛 가로", range: 0...1, def: 0.35),
                            EffectParam(key: "cy", title: "빛 세로", range: 0...1, def: 0.7),
                            EffectParam(key: "height", title: "빛 높이", range: 0.05...2, def: 0.5),
                            EffectParam(key: "brightness", title: "밝기", range: 0...10, def: 3),
                            EffectParam(key: "focus", title: "빛 퍼짐 (작을수록 넓다)", range: 0.01...1, def: 0.1)]) { i, v, _ in
            let e = i.extent, m = max(e.width, e.height)
            let c = center(i, v)
            return i.applyingFilter("CISpotLight", parameters: [
                "inputLightPosition": CIVector(x: c.x, y: c.y, z: m * CGFloat(v("height"))),
                "inputLightPointsAt": CIVector(x: e.midX, y: e.midY, z: 0),
                "inputBrightness": v("brightness"), "inputConcentration": v("focus"), "inputColor": CIColor.white])
        },
        EffectSpec(kind: "lensFlare", title: "렌즈 플레어", category: .render,
                   params: [EffectParam(key: "cx", title: "가로", range: 0...1, def: 0.25),
                            EffectParam(key: "cy", title: "세로", range: 0...1, def: 0.75),
                            EffectParam(key: "size", title: "크기", range: 1...400, def: 60, pixels: true),
                            EffectParam(key: "strength", title: "세기", range: 0...1, def: 0.6)]) { i, v, _ in
            let e = i.extent
            let c = center(i, v)
            let sun = CIFilter(name: "CISunbeamsGenerator", parameters: [
                kCIInputCenterKey: c, "inputSunRadius": v("size") * 0.4, "inputMaxStriationRadius": 2.6,
                "inputStriationStrength": v("strength"), "inputStriationContrast": 1.2, "inputTime": 0.3,
                kCIInputColorKey: CIColor(red: 1, green: 0.92, blue: 0.8)])!.outputImage!.cropped(to: e)
            // 가운데를 지나 반대쪽으로 늘어서는 고리들
            var o = i.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: sun])
            let dx = e.midX - c.x, dy = e.midY - c.y
            for (t, r, a) in [(0.6, 0.35, 0.18), (1.2, 0.6, 0.12), (1.6, 0.25, 0.2), (2.0, 0.9, 0.08)] {
                let p = CIVector(x: c.x + dx * CGFloat(t), y: c.y + dy * CGFloat(t))
                let ring = CIFilter(name: "CIRadialGradient", parameters: [
                    kCIInputCenterKey: p, "inputRadius0": v("size") * r * 0.7, "inputRadius1": v("size") * r,
                    "inputColor0": CIColor(red: CGFloat(a), green: CGFloat(a * 0.9), blue: CGFloat(a * 1.2)),
                    "inputColor1": CIColor(red: 0, green: 0, blue: 0)])!.outputImage!.cropped(to: e)
                o = o.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: ring])
            }
            return o
        },
    ]

    static let pixelates: [EffectSpec] = [
        EffectSpec(kind: "mosaic", title: "모자이크", category: .pixelate,
                   params: [EffectParam(key: "size", title: "칸 크기", range: 2...300, def: 24, pixels: true, unit: "px")]) { i, v, _ in
            i.clampedToExtent().applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(v("size"), 1),
                                                                           kCIInputCenterKey: CIVector(x: i.extent.minX, y: i.extent.minY)])
        },
        EffectSpec(kind: "halftone", title: "색상 하프톤", category: .pixelate,
                   params: [EffectParam(key: "size", title: "점 크기", range: 2...100, def: 12, pixels: true, unit: "px")], gamma: true) { i, v, _ in
            i.applyingFilter("CICMYKHalftone", parameters: [kCIInputWidthKey: max(v("size"), 1), kCIInputCenterKey: CIVector(x: i.extent.minX, y: i.extent.minY)])
        },
        EffectSpec(kind: "crystallize", title: "결정화", category: .pixelate,
                   params: [EffectParam(key: "size", title: "칸 크기", range: 2...300, def: 30, pixels: true, unit: "px")]) { i, v, _ in
            i.clampedToExtent().applyingFilter("CICrystallize", parameters: [kCIInputRadiusKey: max(v("size"), 1)])
        },
        EffectSpec(kind: "pointillize", title: "점묘화", category: .pixelate,
                   params: [EffectParam(key: "size", title: "점 크기", range: 2...200, def: 16, pixels: true, unit: "px")]) { i, v, _ in
            i.clampedToExtent().applyingFilter("CIPointillize", parameters: [kCIInputRadiusKey: max(v("size"), 1)])
        },
        EffectSpec(kind: "hexagon", title: "육각 모자이크", category: .pixelate,
                   params: [EffectParam(key: "size", title: "칸 크기", range: 2...300, def: 24, pixels: true, unit: "px")]) { i, v, _ in
            i.clampedToExtent().applyingFilter("CIHexagonalPixellate", parameters: [kCIInputScaleKey: max(v("size"), 1)])
        },
        EffectSpec(kind: "mezzotint", title: "메조틴트", category: .pixelate, params: [], gamma: true) { i, _, _ in
            let n = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: i.extent)
            return mezzoK?.apply(extent: i.extent, arguments: [i, n]) ?? i
        },
    ]

    static let others: [EffectSpec] = [
        EffectSpec(kind: "highPass", title: "하이 패스", category: .other,
                   params: [EffectParam(key: "radius", title: "반경", range: 0.5...250, def: 10, pixels: true, unit: "px")]) { i, v, _ in
            GPU.run("high_pass", [i, i.blurred(max(CGFloat(v("radius")), 0.5))], extent: i.extent)
        },
        EffectSpec(kind: "minimum", title: "최소값", category: .other,
                   params: [EffectParam(key: "radius", title: "반경", range: 1...100, def: 3, pixels: true, unit: "px")]) { i, v, _ in
            i.clampedToExtent().applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: max(v("radius"), 1)])
        },
        EffectSpec(kind: "maximum", title: "최대값", category: .other,
                   params: [EffectParam(key: "radius", title: "반경", range: 1...100, def: 3, pixels: true, unit: "px")]) { i, v, _ in
            i.clampedToExtent().applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(v("radius"), 1)])
        },
        EffectSpec(kind: "offset", title: "오프셋 (감싸기)", category: .other,
                   params: [EffectParam(key: "dx", title: "가로 이동", range: -1...1, def: 0.5),
                            EffectParam(key: "dy", title: "세로 이동", range: -1...1, def: 0.5)]) { i, v, _ in
            let e = i.extent
            let t = NSAffineTransform()
            t.translateX(by: e.width * CGFloat(v("dx")), yBy: e.height * CGFloat(v("dy")))
            return i.applyingFilter("CIAffineTile", parameters: [kCIInputTransformKey: t])
        },
        EffectSpec(kind: "customKernel", title: "사용자 정의 (3×3)", category: .other,
                   params: (0..<9).map { EffectParam(key: "w\($0)", title: "계수 \($0 / 3 + 1)행 \($0 % 3 + 1)열", range: -10...10, def: $0 == 4 ? 5 : ([1, 3, 5, 7].contains($0) ? -1 : 0)) }
                   + [EffectParam(key: "scale", title: "나누기", range: 1...50, def: 1), EffectParam(key: "offset", title: "더하기", range: -1...1, def: 0)],
                   gamma: true) { i, v, _ in
            let s = max(v("scale"), 1)
            let w = (0..<9).map { CGFloat(v("w\($0)") / s) }
            return i.clampedToExtent().applyingFilter("CIConvolution3X3", parameters: [
                "inputWeights": CIVector(values: w, count: 9), "inputBias": v("offset")])
        },
        EffectSpec(kind: "cameraRaw", title: "카메라 로우 필터", category: .other,
                   params: [EffectParam(key: "exposure", title: "노출", range: -4...4, def: 0),
                            EffectParam(key: "contrast", title: "대비", range: -100...100, def: 0),
                            EffectParam(key: "highlight", title: "하이라이트 복구", range: 0...100, def: 0),
                            EffectParam(key: "shadow", title: "섀도", range: -100...100, def: 0),
                            EffectParam(key: "clarity", title: "클래리티", range: -100...100, def: 0),
                            EffectParam(key: "dehaze", title: "디헤이즈", range: 0...100, def: 0),
                            EffectParam(key: "saturation", title: "채도", range: -100...100, def: 0),
                            EffectParam(key: "vibrance", title: "활기", range: -100...100, def: 0)]) { i, v, s in
            // 대량 보정 현상 도구를 이 레이어에 그대로 (가이드는 같은 그림)
            var a = LocalAdjust()
            a.exposure = Float(v("exposure")); a.contrast = Float(v("contrast")); a.highlight = Float(v("highlight"))
            a.shadow = Float(v("shadow")); a.clarity = Float(v("clarity")); a.dehaze = Float(v("dehaze"))
            a.saturation = Float(v("saturation")); a.vibrance = Float(v("vibrance"))
            return Layers.develop(a, i, guide: i, scale: s, guideScale: s).0
        },
    ]

    static let adjusts: [EffectSpec] = [
        EffectSpec(kind: "selectiveColor", title: "선택 색상", category: .adjust,
                   params: ["red", "yellow", "green", "cyan", "blue", "magenta", "whites", "neutrals", "blacks"].enumerated().flatMap { gi, g in
                       let names = ["빨강", "노랑", "초록", "녹청", "파랑", "자홍", "흰색", "중간", "검정"]
                       return ["c", "m", "y", "k"].map { ch in
                           let chName = ["c": "청록", "m": "자홍", "y": "노랑", "k": "검정"][ch]!
                           return EffectParam(key: "\(g)_\(ch)", title: "\(names[gi]) · \(chName)", range: -100...100, def: 0, unit: "%")
                       }
                   }, gamma: true) { i, v, _ in
            guard let k = selectiveK else { return i }
            let groups = ["red", "yellow", "green", "cyan", "blue", "magenta", "whites", "neutrals", "blacks"]
            let vecs = groups.map { g in CIVector(x: v("\(g)_c") / 100, y: v("\(g)_m") / 100, z: v("\(g)_y") / 100, w: v("\(g)_k") / 100) }
            return k.apply(extent: i.extent, arguments: [i] + vecs) ?? i
        },
        EffectSpec(kind: "replaceColor", title: "색상 대체", category: .adjust,
                   params: [EffectParam(key: "hue", title: "바꿀 색조", range: 0...360, def: 0, unit: "°"),
                            EffectParam(key: "range", title: "허용 범위", range: 5...180, def: 30, unit: "°"),
                            EffectParam(key: "shift", title: "색조 옮기기", range: -180...180, def: 120, unit: "°"),
                            EffectParam(key: "sat", title: "채도", range: -100...100, def: 0),
                            EffectParam(key: "light", title: "밝기", range: -100...100, def: 0)]) { i, v, _ in
            var r = ColorRange(name: "대체", hue: Float(v("hue")), width: Float(v("range")))
            r.dHue = Float(v("shift")); r.dSat = Float(v("sat")); r.dLight = Float(v("light"))
            var key = ColorLUT.Key()
            key.editor = [r]
            return ColorLUT.apply(key, to: i)
        },
        EffectSpec(kind: "equalize", title: "균일화", category: .adjust, params: [], gamma: true) { i, _, _ in
            equalize(i)
        },
        EffectSpec(kind: "matchColor", title: "색상 일치 (밝기·채도·중화)", category: .adjust,
                   params: [EffectParam(key: "luminance", title: "밝기", range: 1...200, def: 100),
                            EffectParam(key: "intensity", title: "채도", range: 1...200, def: 100),
                            EffectParam(key: "fade", title: "흐리게", range: 0...100, def: 0),
                            EffectParam(key: "neutralize", title: "색 중화 (1 켬)", range: 0...1, def: 1)], gamma: true) { i, v, _ in
            matchColor(i, luminance: v("luminance") / 100, intensity: v("intensity") / 100, fade: v("fade") / 100, neutralize: v("neutralize") >= 0.5)
        },
        EffectSpec(kind: "shadowsHighlights", title: "어두운 영역/밝은 영역", category: .adjust,
                   params: [EffectParam(key: "shadows", title: "어두운 영역", range: 0...100, def: 35, unit: "%"),
                            EffectParam(key: "highlights", title: "밝은 영역", range: 0...100, def: 0, unit: "%"),
                            EffectParam(key: "radius", title: "반경", range: 1...500, def: 30, pixels: true, unit: "px")]) { i, v, _ in
            i.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputShadowAmount": v("shadows") / 100, "inputHighlightAmount": 1 - v("highlights") / 100,
                kCIInputRadiusKey: max(v("radius"), 1)])
        },
        EffectSpec(kind: "hdrToning", title: "HDR 토닝", category: .adjust,
                   params: [EffectParam(key: "strength", title: "가장자리 광선 강도", range: 0...4, def: 1),
                            EffectParam(key: "radius", title: "가장자리 광선 반경", range: 1...500, def: 80, pixels: true, unit: "px"),
                            EffectParam(key: "gamma", title: "감마", range: 0.1...2, def: 1),
                            EffectParam(key: "exposure", title: "노출", range: -5...5, def: 0),
                            EffectParam(key: "detail", title: "세부", range: -100...300, def: 30, unit: "%"),
                            EffectParam(key: "saturation", title: "채도", range: -100...100, def: 20)]) { i, v, _ in
            var o = i.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: v("exposure")])
            o = o.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputShadowAmount": 0.6, "inputHighlightAmount": 0.4,
                                                                          kCIInputRadiusKey: max(v("radius"), 1)])
            o = o.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: max(v("radius"), 1),
                                                                                  kCIInputIntensityKey: v("strength") * 0.5]).cropped(to: i.extent)
            if v("detail") != 0 {
                o = o.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 2,
                                                                                      kCIInputIntensityKey: v("detail") / 100]).cropped(to: i.extent)
            }
            o = o.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1 / max(v("gamma"), 0.1)])
            return o.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 + v("saturation") / 100])
        },
    ]

    static let artistic: [EffectSpec] = [
        EffectSpec(kind: "comic", title: "만화 (예술 효과)", category: .gallery, params: [], gamma: true) { i, _, _ in
            i.applyingFilter("CIComicEffect")
        },
        EffectSpec(kind: "sketch", title: "스케치 (연필)", category: .gallery,
                   params: [EffectParam(key: "radius", title: "선 굵기", range: 1...10, def: 3)], gamma: true) { i, v, _ in
            // 흑백 반전을 흐려 색상 닷지로 합치면 연필 스케치
            let g = gray(i), inv = g.applyingFilter("CIColorInvert").blurred(CGFloat(v("radius")))
            return inv.applyingFilter("CIColorDodgeBlendMode", parameters: [kCIInputBackgroundImageKey: g])
        },
        EffectSpec(kind: "charcoal", title: "목탄 (스케치)", category: .gallery, params: [], gamma: true) { i, _, _ in
            gray(i).applyingFilter("CIEdgeWork", parameters: [kCIInputRadiusKey: 3]).applyingFilter("CIColorInvert")
        },
        EffectSpec(kind: "watercolor", title: "수채화 (예술 효과)", category: .gallery,
                   params: [EffectParam(key: "radius", title: "붓 크기", range: 1...6, def: 3)], gamma: true) { i, v, s in
            let k = max(min(s, 1), 0.25)
            let p = general(kuwaharaK, i.transformed(by: .init(scaleX: k, y: k)), pad: 7, [v("radius")])
                .transformed(by: .init(scaleX: 1 / k, y: 1 / k))
            let edges = p.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 1]).applyingFilter("CIColorInvert")
            return p.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: edges])
        },
        EffectSpec(kind: "texture", title: "텍스처 (거친 종이)", category: .gallery,
                   params: [EffectParam(key: "amount", title: "양", range: 0...1, def: 0.3)], gamma: true) { i, v, s in
            let paper = clouds(i.extent, scale: s * 0.05, seed: 11).applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 2])
            let relief = paper.clampedToExtent().applyingFilter("CIConvolution3X3", parameters: [
                "inputWeights": CIVector(values: [-1, -1, 0, -1, 0, 1, 0, 1, 1], count: 9), "inputBias": 0.5]).cropped(to: i.extent)
            let mixed = relief.applyingFilter("CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: i])
            return mixed.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: mixed, kCIInputImageKey: i, kCIInputTimeKey: v("amount")])
        },
        EffectSpec(kind: "thermal", title: "열화상", category: .gallery, params: [], gamma: true) { i, _, _ in i.applyingFilter("CIThermal") },
        EffectSpec(kind: "xray", title: "엑스레이", category: .gallery, params: [], gamma: true) { i, _, _ in i.applyingFilter("CIXRay") },
        EffectSpec(kind: "kaleidoscope", title: "만화경", category: .gallery,
                   params: [EffectParam(key: "count", title: "조각 수", range: 2...24, def: 6)]) { i, v, _ in
            i.clampedToExtent().applyingFilter("CIKaleidoscope", parameters: [
                "inputCount": v("count"), kCIInputCenterKey: CIVector(x: i.extent.midX, y: i.extent.midY)])
        },
    ]

    // MARK: - 계산이 필요한 조정

    /// 균일화: 밝기 누적 분포로 톤 곡선을 만든다 (화면 값에서)
    static func equalize(_ i: CIImage) -> CIImage {
        let e = i.extent
        let small = i.transformed(by: .init(scaleX: 256 / max(e.width, 1), y: 256 / max(e.height, 1)))
        let r = small.extent.integral
        let w = Int(r.width), h = Int(r.height)
        guard w > 2, h > 2 else { return i }
        var buf = [Float](repeating: 0, count: w * h * 4)
        Render.context.render(small, toBitmap: &buf, rowBytes: w * 16, bounds: r, format: .RGBAf, colorSpace: nil)
        var hist = [Double](repeating: 0, count: 64)
        for p in 0..<(w * h) {
            let y = 0.2126 * buf[p * 4] + 0.7152 * buf[p * 4 + 1] + 0.0722 * buf[p * 4 + 2]
            hist[min(max(Int(y * 63.99), 0), 63)] += 1
        }
        var cdf = [Double](repeating: 0, count: 64), acc = 0.0
        for k in 0..<64 { acc += hist[k]; cdf[k] = acc / Double(w * h) }
        // 64칸 곡선 → 16³ 색 큐브 (밝기 비율을 곱해 색은 유지)
        let n = 16
        var cube = [Float](repeating: 0, count: n * n * n * 4)
        for b in 0..<n { for g in 0..<n { for rr in 0..<n {
            let c = SIMD3<Float>(Float(rr), Float(g), Float(b)) / Float(n - 1)
            let y = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
            let yy = Float(cdf[min(max(Int(y * 63.99), 0), 63)])
            let k = y > 0.001 ? yy / y : 1
            let o = simd.simd_clamp(c * k, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
            let idx = ((b * n + g) * n + rr) * 4
            cube[idx] = o.x; cube[idx + 1] = o.y; cube[idx + 2] = o.z; cube[idx + 3] = 1
        } } }
        let data = cube.withUnsafeBufferPointer { Data(buffer: $0) }
        return i.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": n, "inputCubeData": data])
    }

    /// 색상 일치 (한 장 방식): 평균 색을 회색으로 중화하고 밝기·채도를 곱한다
    static func matchColor(_ i: CIImage, luminance: Double, intensity: Double, fade: Double, neutralize: Bool) -> CIImage {
        let avg = i.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: i.extent)])
        var px = [Float](repeating: 0, count: 4)
        Render.context.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        let y = max(0.2126 * px[0] + 0.7152 * px[1] + 0.0722 * px[2], 0.001)
        var o = i
        if neutralize {
            o = o.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(y / max(px[0], 0.001)), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: CGFloat(y / max(px[1], 0.001)), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(y / max(px[2], 0.001)), w: 0)])
        }
        o = o.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: intensity, kCIInputBrightnessKey: 0])
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: log2(max(luminance, 0.01)) / 2.2])
        if fade > 0 {
            o = o.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: i, kCIInputTimeKey: fade])
        }
        return o
    }
}
