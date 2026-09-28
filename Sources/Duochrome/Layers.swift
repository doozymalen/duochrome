import CoreImage

/// 조정 레이어가 바꾸는 값. 현상 조정과 색 조정 레이어를 하나로 합쳤다.
/// 모두 0이 "그대로"다.
struct LocalAdjust: Equatable, Codable {
    /// 필터(흐림·선명 등)가 하나라도 켜졌는지
    var hasFilter: Bool { blur > 0 || motionBlur > 0 || highPass > 0 || noise > 0 || median > 0 || sharpen > 0 || (skinSmooth ?? 0) > 0 }
    var exposure: Float = 0        // EV
    var contrast: Float = 0        // -100~100
    var brightness: Float = 0
    var saturation: Float = 0
    var highlight: Float = 0       // 0~100
    var shadow: Float = 0
    var clarity: Float = 0         // -100~100
    var dehaze: Float = 0          // 0~100
    var temperature: Float = 0     // -100 차갑게 ~ 100 따뜻하게
    var tint: Float = 0            // -100 초록 ~ 100 자홍
    // 색 조정
    var vibrance: Float = 0        // 활기 -100~100
    var hue: Float = 0             // 색조 돌리기 -180~180°
    var filterHue: Float = 35      // 포토 필터 색조 (35° = 따뜻한 필터 85)
    var filterDensity: Float = 0   // 포토 필터 농도 0~100
    var invert: Float = 0          // 1이면 반전
    var posterize: Float = 0       // 0 끔, 2~32 단계
    var threshold: Float = 0       // 0 끔, 1~255
    /// 그라디언트 맵: 비었으면 끔. 어두운 색 RGB + 밝은 색 RGB (0~1, 화면 값)
    var gradientMap: [Float] = []
    /// 여러 색 그라디언트 맵 (위치, 가운데점, r, g, b 반복). 있으면 gradientMap 대신 쓴다
    var gradientStops: [Float]? = nil
    /// 채널 혼합: 비었으면 끔. 3×3 (행: 출력 빨강·초록·파랑, 열: 입력 빨강·초록·파랑)
    var mixer: [Float] = []
    // 필터 (반경은 원본 픽셀)
    var blur: Float = 0            // 가우시안 흐림
    var motionBlur: Float = 0      // 동작 흐림 거리
    var motionAngle: Float = 0     // 동작 흐림 각도 (°)
    var highPass: Float = 0        // 하이 패스 반경 (0 끔). 오버레이로 섞으면 주파수 분리 리터칭
    var noise: Float = 0           // 노이즈 추가 0~100
    var median: Float = 0          // 중간값 (먼지와 스크래치) 0~5
    var sharpen: Float = 0         // 선명 효과 0~300
    /// 피부 매끈하게 0~100: 얼룩은 고르게, 모공 같은 잔 질감은 남긴다
    var skinSmooth: Float? = nil
    /// .cube LUT (레이어 그림 폴더의 파일 이름). 비었으면 끔. sRGB 화면 값에서 건다.
    var lut: String = ""
    /// 레이어 효과 (스마트 필터처럼 차례로 쌓는다, Effects.swift). 예전 문서에는 없어서 선택 항목
    var effects: [LayerEffect]? = nil
    var fx: [LayerEffect] { effects ?? [] }
}

/// 브러시 마스크의 붓질 하나 (디코딩 원본 좌표).
struct MaskStroke: Equatable, Hashable, Codable {
    var points: [Double]           // x0, y0, x1, y1, …
    var radius: Double
    var hardness: Double = 0.5     // 0 부드럽게 ~ 1 딱딱하게
    var flow: Double = 1
    var erase = false
    /// 가져온 붓 끝 (프리셋 폴더의 그림). 있으면 선 대신 붓 끝을 찍는다.
    var tip: String? = nil
    /// 붓 끝 간격 (지름의 비율)
    var spacing: Double? = nil
}

/// 레이어 마스크. 좌표는 모두 디코딩 원본 좌표라 형태 보정을 거쳐 사진과 같이 움직인다.
struct LayerMask: Equatable, Codable {
    enum Kind: String, Codable { case full, brush, linear, radial, rect, ellipse, polygon, image }
    var kind: Kind = .full
    var strokes: [MaskStroke] = []
    /// 선형: 시작점(효과 100%) → 끝점(0%).
    var linear: [Double] = [0, 0, 0, 0]
    /// 원형: 가운데 x, y, 반지름 x, 반지름 y. 안쪽이 100%.
    var radial: [Double] = [0, 0, 0, 0]
    /// 원형 가장자리 부드러움 0~1.
    var radialFeather: Double = 0.5
    /// 사각형·타원 선택: 두 모서리 x0, y0, x1, y1 (원본 좌표)
    var box: [Double] = [0, 0, 0, 0]
    /// 올가미 선택: x0, y0, x1, y1, … (원본 좌표, 닫힌 다각형)
    var polygon: [Double] = []
    /// AI 선택 마스크 그림 (레이어 그림 폴더의 흑백 PNG, 원본 좌표 전체를 덮는다)
    var maskFile: String = ""
    var invert = false
    /// 마스크 전체를 더 흐리게 (원본 픽셀).
    var feather: Double = 0
    /// 루마 레인지: 이 밝기 범위(화면 값 0~1)에서만 효과가 난다.
    var lumaMin: Float = 0
    var lumaMax: Float = 1
    var lumaSoft: Float = 0.1
    var hasLumaRange: Bool { lumaMin > 0 || lumaMax < 1 }

    // 선택 (예전 문서에는 없어서 모두 선택 항목)
    /// 선택 더하기·빼기·교차: 이 마스크 모양에 차례로 합친다
    var combos: [MaskCombo]? = nil
    /// 확장(+)·축소(−), 원본 픽셀
    var grow: Double? = nil
    /// 테두리: 가장자리 둘레 이 폭만 (원본 픽셀)
    var border: Double? = nil
    /// 선택 및 마스크: 매끄럽게(원본 픽셀), 대비(0~100), 가장자리 이동(−100~100 %)
    var smooth: Double? = nil
    var contrast: Double? = nil
    var shiftEdge: Double? = nil
    /// 가장자리 다듬기(머리카락·나뭇가지): 사진 밝기를 길잡이로 마스크를 다듬는 반경 (원본 픽셀)
    var refine: Double? = nil
    /// 색상 범위: 화면 값 RGB + 허용량(0~1). 이 색에 가까운 곳만
    var colorRange: [Float]? = nil
    /// 브러시 마스크를 흰색(전체 보임)에서 시작 (지우개로 가리기)
    var brushWhite: Bool? = nil
    /// 벡터 마스크 (펜 패스, 원본 좌표)
    var vector: VectorPath? = nil
}

/// 마스크 합치기 한 단계 (합칠 모양은 합치기를 더 갖지 않는다)
struct MaskCombo: Equatable, Codable {
    enum Op: String, Codable { case add, subtract, intersect }
    var op: Op
    var mask: LayerMask
}

/// 이미지 레이어의 그림: 레이어 그림 폴더의 파일과, 디코딩 원본 좌표에서의 자리.
/// 사진과 같은 형태 보정(회전·키스톤·크롭)을 거쳐 사진에 붙어 움직인다.
struct LayerImage: Equatable, Codable {
    var file: String
    /// 가운데 (원본 픽셀), 너비 (원본 픽셀), 회전 (°, 반시계 +)
    var cx: Double
    var cy: Double
    var width: Double
    var rotation: Double = 0
    /// 자유 변형(원근·왜곡·기울이기): 네 모서리 원본 좌표 (왼아래, 오른아래, 오른위, 왼위). 있으면 자리·크기·회전 대신
    var quad: [Double]? = nil
    /// 뒤틀기 격자: 4×4 베지어 조절점 (원본 좌표, 아래 줄부터)
    var mesh: [Double]? = nil
    /// 퍼펫 핀: (원래 x, y, 옮긴 x, y) 반복
    var pins: [Double]? = nil
    /// 세로 크기 (원본 픽셀). 없으면 그림 비율대로 (자유 변형에서 비율을 바꾸면 생긴다)
    var height: Double?
}

struct AdjustLayer: Equatable, Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var enabled = true
    var opacity: Float = 1
    var blend: String = "normal"
    var adjust = LocalAdjust()
    var mask = LayerMask()
    /// 잠금: 마스크 칠하기와 값 바꾸기를 막는다.
    var locked = false
    /// 클리핑 마스크: 바로 아래 레이어의 마스크 안에서만 효과가 난다 (⌥⌘G).
    var clipped = false
    /// "adjust" 조정 레이어, "image" 이미지(픽셀) 레이어, "group" 그룹.
    var kind = "adjust"
    /// 칠 불투명도: 레이어 내용에만 건다. 하드 혼합에서는 불투명도와 달리 결과를 부드럽게 한다.
    var fill: Float = 1
    /// 들어 있는 그룹의 id. 그룹의 자식은 배열에서 그룹 항목 바로 앞(아래)에 모여 있다.
    var group: String?
    /// 이미지 레이어의 그림과 자리.
    var image: LayerImage?

    /// 심화 보정 붓 도구가 만든 레이어 (밝게·어둡게 등). 같은 도구를 다시 고르면 이 레이어에 이어 칠한다.
    var preset: String?

    var isGroup: Bool { kind == "group" }
    var isImage: Bool { kind == "image" }
    var isFill: Bool { kind == "fill" }
    /// 배경 복사: 배경(RAW 현상)을 복제한 레이어. 자기 리터칭 점을 가진다
    var isCopy: Bool { kind == "copy" }
    /// 배경 복사 레이어의 리터칭 점 (원본 좌표)
    var spots: [RetouchSpot] = []
    /// 칠 레이어 색: RGB 셋(단색) 또는 여섯(그라디언트: 시작 색 + 끝 색), 화면 값 0~1
    var fillColor: [Float] = []
    /// 그라디언트 칠의 시작·끝 (원본 좌표 x0, y0, x1, y1)
    var fillPoints: [Double] = []
    /// 레이어 스타일 (그림자·획·광선 등, LayerStyles.swift). 모양이 있는 레이어(이미지·칠·글자·모양)만
    var styles: LayerStyles? = nil
    /// 혼합 조건: 이 레이어 밝기 [검정 시작, 검정 끝, 흰 시작, 흰 끝] + 아래 레이어 같은 넷 (화면 값 0~1)
    var blendIf: [Float]? = nil
    /// 칠 무늬: nil 단색·그라디언트, 0 체크, 1 줄무늬, 2 구름, 3 점 (색 1·2는 fillColor 여섯 값)
    var fillPattern: Int? = nil
    var fillScale: Float? = nil
    /// 가져온 패턴 그림 (레이어 그림 폴더). 있으면 이 그림을 바둑판으로 깐다
    var fillPatternFile: String? = nil
    /// 여러 색 그라디언트 칠 (위치, 가운데점, r, g, b 반복)
    var fillStops: [Float]? = nil
    /// 연결: 같은 값의 레이어는 함께 옮긴다
    var link: String? = nil
    /// 글자 레이어 내용 (kind "text"). PSD에서 가져온 글자는 파일에 든 그림(image)을 고치기 전까지 쓴다.
    var text: LayerText? = nil
    /// 픽셀 유동화 붓질 (원본 좌표)
    var liquify: [LiquifyStroke]? = nil
    /// 칠 레이어 붓질 (kind "paint")
    var paint: [PaintStroke]? = nil
    /// PSD에서 가져온 조정 레이어의 원래 자료 ("키:base64") — 고치지 않았으면 PSD로 내보낼 때 그대로 쓴다
    var psdBlock: String? = nil
    /// 모양 레이어 (kind "shape"): 패스·채우기·획
    var vector: VectorShape? = nil
    var isText: Bool { kind == "text" }
    /// 스타일을 입힐 수 있는 레이어
    var takesStyles: Bool { isImage || isFill || kind == "text" || kind == "shape" || kind == "paint" }

    /// PSD 혼합 모드와 이름 → Core Image 필터.
    static let blendModes: [(String, String, String?)] = [
        ("normal", "표준", nil),
        ("multiply", "곱하기", "CIMultiplyBlendMode"), ("screen", "스크린", "CIScreenBlendMode"),
        ("overlay", "오버레이", "CIOverlayBlendMode"), ("softLight", "소프트 라이트", "CISoftLightBlendMode"),
        ("hardLight", "하드 라이트", "CIHardLightBlendMode"), ("darken", "어둡게", "CIDarkenBlendMode"),
        ("lighten", "밝게", "CILightenBlendMode"), ("colorDodge", "색상 닷지", "CIColorDodgeBlendMode"),
        ("colorBurn", "색상 번", "CIColorBurnBlendMode"), ("linearDodge", "선형 닷지", "CILinearDodgeBlendMode"),
        ("linearBurn", "선형 번", "CILinearBurnBlendMode"), ("difference", "차이", "CIDifferenceBlendMode"),
        ("exclusion", "제외", "CIExclusionBlendMode"), ("hue", "색조", "CIHueBlendMode"),
        ("saturation", "채도", "CISaturationBlendMode"), ("color", "색상", "CIColorBlendMode"),
        ("luminosity", "광도", "CILuminosityBlendMode"), ("vividLight", "선명한 라이트", "CIVividLightBlendMode"),
        ("linearLight", "선형 라이트", "CILinearLightBlendMode"), ("pinLight", "핀 라이트", "CIPinLightBlendMode"),
        ("subtract", "빼기", "CISubtractBlendMode"), ("divide", "나누기", "CIDivideBlendMode"),
        ("darkerColor", "어두운 색상", "CIDarkerColorBlendMode"), ("lighterColor", "밝은 색상", "CILighterColorBlendMode"),
        ("hardMix", "하드 혼합", nil), ("dissolve", "디졸브", nil),
    ]
    /// 그룹 전용: 자식이 아래 레이어에 바로 겹친다
    static let passThrough = ("passThrough", "통과")
}

/// 조정 레이어 합성. 아래 레이어까지 합친 결과에 이 레이어의 조정을 걸고, 혼합 모드로 합친 뒤
/// 마스크 × 불투명도만큼 섞는다.
enum Layers {
    /// `shape`: 원본 좌표 마스크를 형태 보정·크롭해 화면 틀에 맞춘다 (사진과 같은 변환).
    static func apply(_ layers: [AdjustLayer], to image: CIImage, guide: CIImage, scale: CGFloat,
                      guideScale gs: CGFloat, native: CGSize, shape: (CIImage, CGFloat) -> CIImage,
                      toDisplay: ((CGPoint) -> CGPoint)? = nil, gamma: Bool = false) -> CIImage {
        // 감마 혼합: 섞기·혼합 모드를 화면 감마 값에서 한다 (PSD 문서). 그림 그래프는 여기서 바로 만들어지므로
        // 이 스레드에만 표시해 둔다.
        let td = Thread.current.threadDictionary
        let saved = td[gammaKey]
        td[gammaKey] = gamma
        defer { td[gammaKey] = saved }
        var out = image, g = guide
        var below: CIImage?        // 바로 아래 레이어의 마스크 (클리핑용)
        var belowG: CIImage?
        let byID = Dictionary(layers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func visible(_ l: AdjustLayer, depth: Int = 0) -> Bool {
            guard l.enabled, l.opacity > 0, depth < 32 else { return false }
            guard let p = l.group.flatMap({ byID[$0] }) else { return true }
            return visible(p, depth: depth + 1)
        }
        // 그룹이 시작될 때의 결과 (그룹 불투명도·마스크를 여기와 섞는다)
        var groupStart: [String: (CIImage, CIImage)] = [:]
        for layer in layers where visible(layer) {
            var p = layer.group
            var guardDepth = 0
            while let gid = p, guardDepth < 32 {
                if groupStart[gid] == nil { groupStart[gid] = (out, g) }
                p = byID[gid]?.group
                guardDepth += 1
            }
            var mask = maskImage(layer.mask, scale: scale, native: native, shape: shape, base: out)
            if layer.clipped, let b = below { mask = multiply(mask, b) }
            below = mask
            let fill = layer.fill
            let blendedOut: CIImage, blendedG: CIImage
            if layer.isGroup {
                guard let (s0, g0) = groupStart[layer.id] else { continue }   // 빈 그룹
                let mode = layer.blend == passThroughKey ? "normal" : layer.blend
                // 통과: 자식이 이미 겹친 결과를 그룹 시작과 마스크·불투명도로 섞는다.
                out = mix(s0, blend(out, over: s0, mode: mode, fill: 1), mask: mask, opacity: layer.opacity)
                if gs != scale {
                    var gm = maskImage(layer.mask, scale: gs, native: native, shape: shape, base: g0)
                    if layer.clipped, let b = belowG { gm = multiply(gm, b) }
                    belowG = gm
                    g = mix(g0, blend(g, over: g0, mode: mode, fill: 1), mask: gm, opacity: layer.opacity)
                } else {
                    g = out
                }
                continue
            } else if layer.isCopy {
                // 배경을 복제하고 이 레이어의 리터칭 점을 건다 (점은 원본 좌표 → 화면 좌표로 옮긴다)
                let spots = layer.spots.map { mapSpot($0, toDisplay) }
                var content = spots.isEmpty ? image : Retouch.apply(spots, to: image, scale: scale)
                var contentG = spots.isEmpty || gs == scale ? content : Retouch.apply(spots, to: guide, scale: gs)
                if gs == scale { contentG = content }
                let (adjusted, gAdjusted) = develop(layer.adjust, content, guide: contentG, scale: scale, guideScale: gs)
                content = adjusted
                blendedOut = blend(content, over: out, mode: layer.blend, fill: fill)
                blendedG = blend(gAdjusted, over: g, mode: layer.blend, fill: fill)
            } else if layer.isFill {
                var top = Effects.apply(layer.adjust.fx, filled(layer, scale: scale, native: native, shape: shape, frame: out.extent), scale: scale)
                below = multiply(mask, LayerStyles.alphaGray(top))   // 위 레이어는 내용 모양으로 잘린다
                if let st = layer.styles, st.isActive {
                    // 스타일은 마스크 모양을 따라 그린다: 내용을 마스크로 자르고, 뒤에서는 마스크를 다시 걸지 않는다
                    top = LayerStyles.apply(st, cut(top, mask), scale: scale)
                    mask = CIImage(color: .white).cropped(to: out.extent)
                }
                blendedOut = blend(top, over: out, mode: layer.blend, fill: fill)
                blendedG = gs != scale ? blend(filled(layer, scale: gs, native: native, shape: shape, frame: g.extent), over: g,
                                               mode: layer.blend, fill: fill) : g
            } else if layer.isImage || layer.isText || layer.kind == "paint" || layer.kind == "shape" {
                guard let placedTop = placed(layer, scale: scale, native: native, shape: shape, frame: out.extent) else { continue }
                var top = Effects.apply(layer.adjust.fx, placedTop, scale: scale)
                below = multiply(mask, LayerStyles.alphaGray(top))
                if let st = layer.styles, st.isActive {
                    top = LayerStyles.apply(st, cut(top, mask), scale: scale)
                    mask = CIImage(color: .white).cropped(to: out.extent)
                }
                blendedOut = blend(top, over: out, mode: layer.blend, fill: fill)
                if gs != scale, let topG = placed(layer, scale: gs, native: native, shape: shape, frame: g.extent) {
                    blendedG = blend(topG, over: g, mode: layer.blend, fill: fill)
                } else {
                    blendedG = g
                }
            } else {
                let (adjusted, gAdjusted) = develop(layer.adjust, out, guide: g, scale: scale, guideScale: gs)
                blendedOut = blend(adjusted, over: out, mode: layer.blend, fill: fill)
                blendedG = blend(gAdjusted, over: g, mode: layer.blend, fill: fill)
            }
            if let bi = layer.blendIf, bi.count == 8 { mask = multiply(mask, blendIfMask(bi, this: blendedOut, below: out)) }
            if layer.blend == "dissolve" { mask = dissolve(mask, opacity: layer.opacity) }
            out = mix(out, blendedOut, mask: mask, opacity: layer.blend == "dissolve" ? 1 : layer.opacity)
            if gs != scale {
                var gm = maskImage(layer.mask, scale: gs, native: native, shape: shape, base: g)
                if layer.clipped, let b = belowG { gm = multiply(gm, b) }
                if let bi = layer.blendIf, bi.count == 8 { gm = multiply(gm, blendIfMask(bi, this: blendedG, below: g)) }
                belowG = gm
                g = mix(g, blendedG, mask: gm, opacity: layer.opacity)
            } else {
                g = out
            }
        }
        return out
    }

    static let passThroughKey = AdjustLayer.passThrough.0

    /// 원본 좌표 리터칭 점을 화면(형태 보정 뒤) 좌표로. 반지름은 두 점 거리로 배율을 잰다.
    static func mapSpot(_ s: RetouchSpot, _ f: ((CGPoint) -> CGPoint)?) -> RetouchSpot {
        guard let f else { return s }
        var o = s
        let t = f(s.target), src = f(s.source)
        let e = f(CGPoint(x: s.targetX + 100, y: s.targetY))
        let k = hypot(e.x - t.x, e.y - t.y) / 100
        o.targetX = t.x; o.targetY = t.y; o.sourceX = src.x; o.sourceY = src.y
        o.radius = s.radius * k
        if let p = s.path {
            var q = p
            for i in stride(from: 0, to: p.count - 1, by: 2) {
                let m = f(CGPoint(x: p[i], y: p[i + 1])); q[i] = m.x; q[i + 1] = m.y
            }
            o.path = q
        }
        return o
    }

    // MARK: - 칠 레이어

    /// 단색 또는 선형 그라디언트 칠 (칠 레이어). 그라디언트는 원본 좌표라 형태 보정을 따라간다.
    static func filled(_ layer: AdjustLayer, scale: CGFloat, native: CGSize, shape: (CIImage, CGFloat) -> CIImage,
                       frame: CGRect) -> CIImage {
        func color(_ i: Int) -> CIColor {
            let c = layer.fillColor
            guard c.count >= i + 3 else { return CIColor(red: 0.5, green: 0.5, blue: 0.5) }
            return CIColor(red: CGFloat(pow(max(c[i], 0), 2.2)), green: CGFloat(pow(max(c[i + 1], 0), 2.2)),
                           blue: CGFloat(pow(max(c[i + 2], 0), 2.2)), alpha: 1, colorSpace: Render.workingSpace)!
        }
        let nativeRect = CGRect(x: 0, y: 0, width: native.width * scale, height: native.height * scale).integral
        if let file = layer.fillPatternFile, let tile = sourceImage(file), tile.extent.width > 0 {
            // 패턴 크기(%)만큼 키워 원본 좌표에 바둑판으로 깐다
            let k = CGFloat(layer.fillScale ?? 100) / 100 * scale
            let t = tile.transformed(by: .init(translationX: -tile.extent.minX, y: -tile.extent.minY)).transformed(by: .init(scaleX: k, y: k))
            let tiled = t.applyingFilter("CIAffineTile", parameters: [kCIInputTransformKey: NSAffineTransform()]).cropped(to: nativeRect)
            return shape(tiled, scale).cropped(to: frame)
        }
        if let st = layer.fillStops, st.count >= 10, layer.fillPoints.count == 4, let g = gradientImage(st) {
            let p = layer.fillPoints.map { CGFloat($0) * scale }
            let img = gradientRamp(g, from: CGPoint(x: p[0], y: p[1]), to: CGPoint(x: p[2], y: p[3]), extent: nativeRect)
            return shape(img, scale).cropped(to: frame)
        }
        if let p = layer.fillPattern {
            var o = LayerStyles.Overlay()
            o.pattern = p
            o.scale = layer.fillScale ?? 60
            let c = layer.fillColor
            if c.count >= 3 { o.color = Array(c[0..<3]) }
            if c.count >= 6 { o.color2 = Array(c[3..<6]) } else { o.color2 = [0, 0, 0] }
            // 무늬도 원본 좌표에 깔고 형태 보정을 따라간다
            return shape(LayerStyles.pattern(o, nativeRect, scale: scale), scale).cropped(to: frame)
        }
        if layer.fillColor.count == 6, layer.fillPoints.count == 4 {
            let p = layer.fillPoints
            let g = CIFilter(name: "CISmoothLinearGradient", parameters: [
                "inputPoint0": CIVector(x: p[0] * scale, y: p[1] * scale), "inputPoint1": CIVector(x: p[2] * scale, y: p[3] * scale),
                "inputColor0": color(0), "inputColor1": color(3),
            ])!.outputImage!.cropped(to: nativeRect)
            return shape(g, scale).cropped(to: frame)
        }
        return CIImage(color: color(0)).cropped(to: frame)
    }

    /// 여러 색 그라디언트 → 1024×1 그림 (작업 공간 선형 값)
    static func gradientImage(_ stops: [Float]) -> CIImage? {
        let st = stride(from: 0, to: stops.count - 4, by: 5).map {
            PSDAdjust.GradientStop(loc: stops[$0], mid: stops[$0 + 1], color: SIMD3(stops[$0 + 2], stops[$0 + 3], stops[$0 + 4]))
        }
        guard st.count >= 2 else { return nil }
        let n = 1024
        var px = [Float](repeating: 1, count: n * 4)
        for i in 0 ..< n {
            let c = PSDAdjust.sample(st, Float(i) / Float(n - 1))
            px[i * 4] = pow(c.x, 2.2); px[i * 4 + 1] = pow(c.y, 2.2); px[i * 4 + 2] = pow(c.z, 2.2)
        }
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: n * 16, size: CGSize(width: n, height: 1), format: .RGBAf, colorSpace: Render.workingSpace)
    }

    static let rampK = try? CIKernel(source: """
        kernel vec4 k(sampler g, vec2 p0, vec2 d, float w) {
            vec2 c = destCoord();
            float t = clamp(dot(c - p0, d) / max(dot(d, d), 1e-6), 0.0, 1.0);
            return sample(g, samplerTransform(g, vec2(t * (w - 1.0) + 0.5, 0.5)));
        }
        """)

    static func gradientRamp(_ g: CIImage, from a: CGPoint, to b: CGPoint, extent: CGRect) -> CIImage {
        guard let k = rampK else { return CIImage(color: .gray).cropped(to: extent) }
        return k.apply(extent: extent, roiCallback: { _, _ in g.extent }, arguments: [
            g, CIVector(x: a.x, y: a.y), CIVector(x: b.x - a.x, y: b.y - a.y), g.extent.width,
        ]) ?? CIImage(color: .gray).cropped(to: extent)
    }

    // MARK: - 이미지 레이어

    private static var imageCache: [String: CIImage] = [:]
    /// 최근에 쓴 순서 (넘치면 오래된 것 하나만 뺀다. 예전엔 8장이 넘으면 모두 비워, 레이어·마스크 그림이 많은 문서는
    /// 그릴 때마다 그림을 새로 읽었고 그리기 도구가 새 그림마다 버퍼를 만들어 메모리가 수십 GB까지 늘었다)
    private static var imageOrder: [String] = []
    private static let imageLock = NSLock()

    static func sourceImage(_ file: String) -> CIImage? {
        imageLock.lock(); defer { imageLock.unlock() }
        // 연결된 이미지("link:경로"): 원본 파일을 바로 읽고, 파일이 바뀌면 다시 읽는다 (스마트 오브젝트 연결)
        var key = file
        var url = LayerImageStore.url(file)
        if file.hasPrefix("link:") {
            url = URL(fileURLWithPath: String(file.dropFirst(5)))
            let m = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            key = file + "@\(m)"
        }
        if let hit = imageCache[key] {
            if let i = imageOrder.firstIndex(of: key) { imageOrder.remove(at: i) }
            imageOrder.append(key)
            return hit
        }
        guard let img = CIImage(contentsOf: url) else { return nil }
        // 파일에서 읽는 그림은 그릴 때 풀리므로 여럿 들고 있어도 가볍다
        while imageOrder.count >= 64 { imageCache[imageOrder.removeFirst()] = nil }
        imageCache[key] = img
        imageOrder.append(key)
        return img
    }

    /// 이미지 레이어를 원본 좌표에 놓고 사진과 같은 형태 보정을 거쳐 화면 틀에 맞춘다. 바깥은 투명.
    static func placed(_ layer: AdjustLayer, scale: CGFloat, native: CGSize, shape: (CIImage, CGFloat) -> CIImage,
                       frame: CGRect) -> CIImage? {
        if layer.kind == "paint" { return painted(layer, scale: scale, native: native, shape: shape, frame: frame) }
        if layer.kind == "shape", let v = layer.vector { return placedShape(v, scale: scale, native: native, shape: shape, frame: frame) }
        if layer.image == nil, let t = layer.text { return placedText(t, scale: scale, native: native, shape: shape, frame: frame) }
        guard let info = layer.image, let src = sourceImage(info.file), src.extent.width > 0 else { return nil }
        let e = src.extent
        let k = CGFloat(info.width) / e.width
        let ky = info.height.map { CGFloat($0) / e.height } ?? k
        let t = CGAffineTransform(translationX: -e.midX, y: -e.midY)
            .concatenating(.init(scaleX: k, y: ky))
            .concatenating(.init(rotationAngle: CGFloat(info.rotation) * .pi / 180))
            .concatenating(.init(translationX: CGFloat(info.cx), y: CGFloat(info.cy)))
            .concatenating(.init(scaleX: scale, y: scale))
        let nativeRect = CGRect(x: 0, y: 0, width: native.width * scale, height: native.height * scale).integral
        if Warp.needsMesh(info) {
            var canvas = Warp.render(src, info, scale: scale, canvas: nativeRect)
            if let lq = layer.liquify, !lq.isEmpty { canvas = Warp.liquify(canvas, strokes: lq, native: native, scale: scale) }
            return shape(canvas, scale).cropped(to: frame)
        }
        // 줄일 때 계단이 지지 않게 먼저 부드럽게 줄인다.
        var img = src
        let total = k * scale
        if total < 0.5 {
            img = src.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: total, kCIInputAspectRatioKey: ky / k])
            let e2 = img.extent
            let t2 = CGAffineTransform(translationX: -e2.midX, y: -e2.midY)
                .concatenating(.init(rotationAngle: CGFloat(info.rotation) * .pi / 180))
                .concatenating(.init(translationX: CGFloat(info.cx) * scale, y: CGFloat(info.cy) * scale))
            img = img.transformed(by: t2)
        } else {
            img = img.transformed(by: t)
        }
        var canvas = img.cropped(to: nativeRect).composited(over: CIImage(color: .clear).cropped(to: nativeRect))
        if let lq = layer.liquify, !lq.isEmpty { canvas = Warp.liquify(canvas, strokes: lq, native: native, scale: scale) }
        return shape(canvas, scale).cropped(to: frame)
    }

    /// 내용을 마스크 모양으로 자른다 (마스크 밖은 투명)
    static func cut(_ top: CIImage, _ mask: CIImage) -> CIImage {
        top.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), "inputMaskImage": mask])
            .cropped(to: top.extent)
    }

    static let gammaKey = "duochrome.gammaBlend"
    private static var gammaBlend: Bool { (Thread.current.threadDictionary[gammaKey] as? Bool) ?? false }
    /// 작업 공간(선형 Rec.2020) ↔ sRGB 감마 값
    static let srgbSpace = CGColorSpace(name: CGColorSpace.extendedSRGB)!
    static func encode(_ i: CIImage) -> CIImage { i.matchedFromWorkingSpace(to: srgbSpace) ?? i }
    static func decode(_ i: CIImage) -> CIImage { i.matchedToWorkingSpace(from: srgbSpace) ?? i }

    private static func mix(_ base: CIImage, _ top: CIImage, mask: CIImage, opacity: Float) -> CIImage {
        if gammaBlend {
            return decode(mixLinear(encode(base), encode(top), mask: mask, opacity: opacity)).cropped(to: base.extent)
        }
        return mixLinear(base, top, mask: mask, opacity: opacity)
    }

    private static func mixLinear(_ base: CIImage, _ top: CIImage, mask: CIImage, opacity: Float) -> CIImage {
        var m = mask
        if opacity < 1 {
            m = m.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(opacity), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: CGFloat(opacity), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(opacity), w: 0),
            ])
        }
        return top.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: base, kCIInputMaskImageKey: m,
        ]).cropped(to: base.extent)
    }

    static let blendIfK = CIColorKernel(source: """
        kernel vec4 k(__sample t, __sample b, vec4 tr, vec4 br) {
            float lt = pow(clamp(dot(t.rgb, vec3(0.2627, 0.678, 0.0593)), 0.0, 1.0), 1.0 / 2.2);
            float lb = pow(clamp(dot(b.rgb, vec3(0.2627, 0.678, 0.0593)), 0.0, 1.0), 1.0 / 2.2);
            float wt = (tr.y > tr.x ? smoothstep(tr.x, tr.y, lt) : step(tr.x, lt)) * (1.0 - (tr.w > tr.z ? smoothstep(tr.z, tr.w, lt) : step(tr.z + 0.0001, lt)));
            float wb = (br.y > br.x ? smoothstep(br.x, br.y, lb) : step(br.x, lb)) * (1.0 - (br.w > br.z ? smoothstep(br.z, br.w, lb) : step(br.z + 0.0001, lb)));
            float w = wt * wb;
            return vec4(w, w, w, 1.0);
        }
        """)

    /// 혼합 조건 가중치 (이 레이어 결과·아래 결과의 밝기 범위)
    static func blendIfMask(_ v: [Float], this: CIImage, below: CIImage) -> CIImage {
        guard let k = blendIfK else { return CIImage(color: .white).cropped(to: below.extent) }
        let c = v.map { CGFloat($0) }
        return k.apply(extent: below.extent, arguments: [this, below, CIVector(x: c[0], y: c[1], z: c[2], w: c[3]),
                                                           CIVector(x: c[4], y: c[5], z: c[6], w: c[7])]) ?? below
    }

    private static func multiply(_ a: CIImage, _ b: CIImage) -> CIImage {
        a.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: b]).cropped(to: a.extent)
    }

    /// 디졸브: 불투명도만큼의 픽셀을 무작위로 골라 100%로 보인다.
    private static func dissolve(_ mask: CIImage, opacity: Float) -> CIImage {
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: mask.extent)
        return GPU.run("dissolve_mask", [mask, noise], params: [opacity], extent: mask.extent)
    }

    /// `fill`: 칠 불투명도. 위 레이어 내용의 알파에 곱한 뒤 혼합한다 (하드 혼합은 커널이 따로 다룬다).
    private static func blend(_ top: CIImage, over base: CIImage, mode: String, fill: Float) -> CIImage {
        if gammaBlend { return decode(blendLinear(encode(top), over: encode(base), mode: mode, fill: fill)).cropped(to: base.extent) }
        return blendLinear(top, over: base, mode: mode, fill: fill)
    }

    private static func blendLinear(_ top: CIImage, over base: CIImage, mode: String, fill: Float) -> CIImage {
        if mode == "hardMix" { return GPU.run("hard_mix", [top, base], params: [fill], extent: base.extent) }
        var t = top
        if fill < 1 {
            let f = CGFloat(max(fill, 0))
            // CIColorMatrix는 알파를 나눈 색에 작용하므로 알파만 줄인다 (색까지 줄이면 두 번 줄어든다).
            t = t.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: f)])
        }
        guard let filter = AdjustLayer.blendModes.first(where: { $0.0 == mode })?.2 else {
            return t.composited(over: base).cropped(to: base.extent)
        }
        return t.applyingFilter(filter, parameters: [kCIInputBackgroundImageKey: base]).cropped(to: base.extent)
    }

    /// 레이어 조정을 건다. 국소 도구(클래리티·디헤이즈)는 기본 현상과 같은 가이드 방식을 쓴다.
    static func develop(_ a: LocalAdjust, _ image: CIImage, guide: CIImage, scale: CGFloat,
                        guideScale gs: CGFloat) -> (CIImage, CIImage) {
        var out = image, g = guide
        // 필터 (흐림·선명·하이 패스 등)는 먼저 건다. 반경은 원본 픽셀 × 미리보기 배율.
        if a.hasFilter {
            out = filters(a, out, scale: scale)
            g = gs == scale ? out : filters(a, g, scale: gs)
        }
        func pixel(_ img: CIImage, _ sc: CGFloat) -> CIImage {
            var o = img
            if a.exposure != 0 { o = o.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure]) }
            if a.temperature != 0 || a.tint != 0 {
                // 6500K를 기준으로 상대적으로 옮긴다. 양수면 따뜻하게.
                o = o.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0),
                    "inputTargetNeutral": CIVector(x: CGFloat(6500 - a.temperature * 25), y: CGFloat(-a.tint * 0.8)),
                ])
            }
            var s = DevelopSettings()
            s.contrast = a.contrast; s.brightness = a.brightness; s.saturation = a.saturation
            s.highlight = a.highlight; s.shadow = a.shadow
            return colorAdjust(a, Develop.tone(s, o, scale: sc).cropped(to: img.extent))
        }
        if a.dehaze > 0 {
            (out, g) = Develop.dehaze(out, guide: g, guideScale: gs, scale: scale, amount: a.dehaze / 100,
                                      light: 0.9)
        }
        if a.clarity != 0 {
            (out, g) = Develop.localContrast(out, guide: g, guideScale: gs, scale: scale,
                                             amount: a.clarity / 100, radius: 120, eps: 0.01)
        }
        out = pixel(out, scale)
        g = gs == scale ? out : pixel(g, gs)
        if a.fx.contains(where: \.enabled) {
            out = Effects.apply(a.fx, out, scale: scale)
            g = gs == scale ? out : Effects.apply(a.fx, g, scale: gs)
        }
        return (out, g)
    }

    static func filters(_ a: LocalAdjust, _ img: CIImage, scale: CGFloat) -> CIImage {
        let e = img.extent
        var o = img
        if a.median > 0 {
            for _ in 0..<min(Int(a.median.rounded()), 5) { o = o.applyingFilter("CIMedianFilter").cropped(to: e) }
        }
        if a.blur > 0 { o = o.blurred(CGFloat(a.blur) * scale) }
        if a.motionBlur > 0 {
            o = o.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [
                kCIInputRadiusKey: max(CGFloat(a.motionBlur) * scale, 0.5), kCIInputAngleKey: CGFloat(a.motionAngle) * .pi / 180,
            ]).cropped(to: e)
        }
        if a.sharpen > 0 {
            o = o.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: max(1.5 * scale, 0.5), kCIInputIntensityKey: a.sharpen / 100,
            ]).cropped(to: e)
        }
        if a.highPass > 0 { o = GPU.run("high_pass", [o, o.blurred(max(CGFloat(a.highPass) * scale, 0.5))], extent: e) }
        if a.noise > 0 { o = Develop.grain(o, amount: a.noise, size: 10, scale: scale, type: 3) }
        if let sk = a.skinSmooth, sk > 0, let k = skinKernel {
            // 큰 흐림(얼룩 고르게)으로 섞고, 작은 흐림과의 차(잔 질감)는 되살린다
            let big = o.clampedToExtent().blurred(max(14 * scale, 1)).cropped(to: e)
            let small = o.clampedToExtent().blurred(max(1.6 * scale, 0.5)).cropped(to: e)
            o = k.apply(extent: e, arguments: [o, big, small, CGFloat(min(sk, 100) / 100)]) ?? o
        }
        return o
    }

    static let skinKernel = CIColorKernel(source: """
        kernel vec4 skin(__sample o, __sample big, __sample small, float amt) {
            vec3 fine = o.rgb - small.rgb;
            vec3 r = mix(o.rgb, big.rgb, amt) + fine * amt * 0.85;
            return vec4(r, o.a);
        }
        """)

    /// 색 조정 (활기, 색조, 포토 필터, 채널 혼합, 그라디언트 맵, 포스터화, 한계값, 반전).
    static func colorAdjust(_ a: LocalAdjust, _ img: CIImage) -> CIImage {
        let e = img.extent
        var o = img
        if !a.lut.isEmpty, let cube = CubeLUT.load(a.lut) {
            o = o.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": cube.n, "inputCubeData": cube.data,
                "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!,
            ])
        }
        if a.vibrance != 0 { o = o.applyingFilter("CIVibrance", parameters: ["inputAmount": a.vibrance / 100]) }
        if a.hue != 0 { o = o.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: a.hue * .pi / 180]) }
        if a.filterDensity > 0 {
            // 필터 색을 밝기 1로 맞춰 곱한다 (밝기는 거의 그대로, 색만 따뜻하게·차갑게)
            let c = ColorLUT.rgb(a.filterHue, 0.6, 1)
            let y = 0.2627 * c.x + 0.678 * c.y + 0.0593 * c.z
            let d = a.filterDensity / 100
            let k = SIMD3<Float>(repeating: 1) + d * (c / max(y, 0.01) - SIMD3<Float>(repeating: 1))
            o = o.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(k.x), y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: CGFloat(k.y), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(k.z), w: 0),
            ])
        }
        if a.mixer.count == 9 {
            let m = a.mixer.map { CGFloat($0) }
            o = o.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: m[0], y: m[1], z: m[2], w: 0), "inputGVector": CIVector(x: m[3], y: m[4], z: m[5], w: 0),
                "inputBVector": CIVector(x: m[6], y: m[7], z: m[8], w: 0),
            ])
        }
        if let st = a.gradientStops, st.count >= 10, let g = gradientImage(st) {
            // 밝기(화면 감마) → 그라디언트
            let gm = o.applyingFilter("CIColorClamp").applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1 / 2.2])
            let lum = gm.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.3, y: 0.59, z: 0.11, w: 0), "inputGVector": CIVector(x: 0.3, y: 0.59, z: 0.11, w: 0),
                "inputBVector": CIVector(x: 0.3, y: 0.59, z: 0.11, w: 0)])
            o = lum.applyingFilter("CIColorMap", parameters: ["inputGradientImage": g]).cropped(to: e)
        } else if a.gradientMap.count == 6 {
            let g = a.gradientMap.map { CGFloat(pow(max($0, 0), 2.2)) }
            o = o.applyingFilter("CIFalseColor", parameters: [
                "inputColor0": CIColor(red: g[0], green: g[1], blue: g[2], alpha: 1, colorSpace: Render.workingSpace)!,
                "inputColor1": CIColor(red: g[3], green: g[4], blue: g[5], alpha: 1, colorSpace: Render.workingSpace)!,
            ])
        }
        // 포스터화·한계값·반전은 화면 감마에서 (선형에서 하면 단계가 어두운 쪽에 몰린다)
        if a.posterize >= 2 || a.threshold > 0 || a.invert >= 0.5 {
            var gm = o.applyingFilter("CIColorClamp").applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1 / 2.2])
            if a.posterize >= 2 { gm = gm.applyingFilter("CIColorPosterize", parameters: ["inputLevels": a.posterize]) }
            if a.threshold > 0 { gm = gm.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": a.threshold / 255]) }
            if a.invert >= 0.5 { gm = gm.applyingFilter("CIColorInvert") }
            o = gm.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 2.2])
        }
        return o.cropped(to: e)
    }

    // MARK: - 마스크

    /// 마스크 이미지 (흑백, 화면 틀 좌표). `base`는 루마 레인지 판단에 쓰는 아래 레이어까지의 결과.
    static func maskImage(_ m: LayerMask, scale: CGFloat, native: CGSize, shape: (CIImage, CGFloat) -> CIImage,
                          base: CIImage) -> CIImage {
        let nativeRect = CGRect(x: 0, y: 0, width: native.width * scale, height: native.height * scale).integral
        var mask = shapeMask(m, scale: scale, native: native)
        // 벡터 마스크: 패스 안만 (래스터 마스크와 곱한다)
        if let v = m.vector, !v.isEmpty {
            mask = mask.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: VectorRender.mask(v, scale: scale, nativeRect: nativeRect)]).cropped(to: nativeRect)
        }
        // 선택 더하기·빼기·교차 (원본 좌표에서)
        for c in m.combos ?? [] {
            let other = shapeMask(c.mask, scale: scale, native: native)
            let o = c.mask.invert ? other.applyingFilter("CIColorInvert") : other
            switch c.op {
            case .add: mask = mask.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: o])
            case .intersect: mask = mask.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: o])
            case .subtract: mask = mask.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: o.applyingFilter("CIColorInvert")])
            }
            mask = mask.cropped(to: nativeRect)
        }
        // 확장·축소·테두리·매끄럽게·대비·가장자리 이동
        if let g = m.grow, abs(g) >= 0.5 {
            let r = max(abs(g) * scale, 0.5)
            mask = mask.clampedToExtent().applyingFilter(g > 0 ? "CIMorphologyMaximum" : "CIMorphologyMinimum", parameters: [kCIInputRadiusKey: r]).cropped(to: nativeRect)
        }
        if let b = m.border, b >= 0.5 {
            let r = max(b / 2 * scale, 0.5)
            let outer = mask.clampedToExtent().applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: r]).cropped(to: nativeRect)
            let inner = mask.clampedToExtent().applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: r]).cropped(to: nativeRect)
            mask = outer.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: inner.applyingFilter("CIColorInvert")]).cropped(to: nativeRect)
        }
        if let sm = m.smooth, sm >= 0.5 {
            mask = mask.clampedToExtent().blurred(CGFloat(sm) * scale).cropped(to: nativeRect)
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1 + sm / 20]).applyingFilter("CIColorClamp")
        }
        if m.feather > 0 { mask = mask.blurred(CGFloat(m.feather) * scale) }
        if (m.contrast ?? 0) > 0 || (m.shiftEdge ?? 0) != 0 {
            // 가운데(0.5)를 옮기고 기울기를 키운다
            let k = 1 + CGFloat(m.contrast ?? 0) / 10, sh = CGFloat(m.shiftEdge ?? 0) / 200
            mask = mask.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
                "inputBiasVector": CIVector(x: 0.5 - 0.5 * k + sh * k, y: 0.5 - 0.5 * k + sh * k, z: 0.5 - 0.5 * k + sh * k, w: 0)])
                .applyingFilter("CIColorClamp").cropped(to: nativeRect)
        }
        var shaped = shape(mask, scale)
        if m.invert { shaped = shaped.applyingFilter("CIColorInvert") }
        if m.hasLumaRange {
            shaped = GPU.run("luma_range", [shaped, base], params: [m.lumaMin, m.lumaMax, max(m.lumaSoft, 0.001)],
                             extent: base.extent)
        }
        if let cr = m.colorRange, cr.count >= 4, let k = colorRangeK {
            let w = k.apply(extent: base.extent, arguments: [base, CIVector(x: CGFloat(cr[0]), y: CGFloat(cr[1]), z: CGFloat(cr[2])), max(CGFloat(cr[3]), 0.01)]) ?? base
            shaped = shaped.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: w])
        }
        if let r = m.refine, r >= 0.5 {
            shaped = refineMask(shaped, guide: base, radius: max(CGFloat(r) * scale, 1))
        }
        return shaped.cropped(to: base.extent)
    }

    /// 색상 범위: 화면 값에서 고른 색과의 거리 → 가까우면 1 (허용량 안에서 부드럽게)
    static let colorRangeK = CIColorKernel(source: """
        kernel vec4 k(__sample s, vec3 c, float fuzz) {
            vec3 d = pow(clamp(s.rgb, 0.0, 1.0), vec3(1.0 / 2.2)) - c;
            float w = 1.0 - smoothstep(fuzz * 0.5, fuzz, length(d));
            return vec4(w, w, w, 1.0);
        }
        """)

    /// 가장자리 다듬기: 사진 밝기를 길잡이로 한 가이디드 필터 (머리카락·잔가지에 마스크가 붙는다)
    static func refineMask(_ mask: CIImage, guide: CIImage, radius r: CGFloat) -> CIImage {
        let e = mask.extent
        let I = guide.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0]).applyingFilter("CIColorClamp").cropped(to: e)
        let p = mask.cropped(to: e)
        func box(_ x: CIImage) -> CIImage { x.clampedToExtent().applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: r]).cropped(to: e) }
        func mul(_ a: CIImage, _ b: CIImage) -> CIImage { a.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: b]).cropped(to: e) }
        guard let k = guidedK else { return mask }
        let mI = box(I), mp = box(p), mIp = box(mul(I, p)), mII = box(mul(I, I))
        let ab = k.apply(extent: e, arguments: [mI, mp, mIp, mII, 0.0004]) ?? mask
        // ab: r = a, g = b → 다시 평균해서 q = a·I + b
        let mab = box(ab)
        return applyAB?.apply(extent: e, arguments: [mab, I]) ?? mask
    }
    static let guidedK = CIColorKernel(source: """
        kernel vec4 k(__sample mI, __sample mp, __sample mIp, __sample mII, float eps) {
            float cov = mIp.r - mI.r * mp.r; float v = mII.r - mI.r * mI.r;
            float a = cov / (v + eps); float b = mp.r - a * mI.r;
            return vec4(a, b, 0.0, 1.0);
        }
        """)
    static let applyAB = CIColorKernel(source: """
        kernel vec4 k(__sample ab, __sample I) {
            float q = clamp(ab.r * I.r + ab.g, 0.0, 1.0);
            return vec4(q, q, q, 1.0);
        }
        """)

    /// 마스크 모양 하나 (원본 좌표·배율, 합치기·다듬기 전)
    static func shapeMask(_ m: LayerMask, scale: CGFloat, native: CGSize) -> CIImage {
        let nativeRect = CGRect(x: 0, y: 0, width: native.width * scale, height: native.height * scale).integral
        var mask: CIImage
        switch m.kind {
        case .full:
            mask = CIImage(color: .white).cropped(to: nativeRect)
        case .linear:
            let p = m.linear
            mask = CIFilter(name: "CISmoothLinearGradient", parameters: [
                "inputPoint0": CIVector(x: p[0] * scale, y: p[1] * scale),
                "inputPoint1": CIVector(x: p[2] * scale, y: p[3] * scale),
                "inputColor0": CIColor.white, "inputColor1": CIColor.black,
            ])!.outputImage!.cropped(to: nativeRect)
        case .radial:
            let p = m.radial
            let rx = max(p[2] * scale, 1), ry = max(p[3] * scale, 1)
            // 원을 그린 뒤 세로로 늘여 타원으로 만든다.
            let inner = rx * (1 - m.radialFeather * 0.9)
            mask = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: 0, y: 0), "inputRadius0": inner, "inputRadius1": max(rx, inner + 0.5),
                "inputColor0": CIColor.white, "inputColor1": CIColor.black,
            ])!.outputImage!
                .transformed(by: CGAffineTransform(scaleX: 1, y: ry / rx).concatenating(.init(translationX: p[0] * scale, y: p[1] * scale)))
                .cropped(to: nativeRect)
        case .brush:
            mask = brushMask(m.strokes, scale: scale, native: native, white: m.brushWhite ?? false).cropped(to: nativeRect)
        case .rect:
            let b = m.box
            let r = CGRect(x: min(b[0], b[2]) * scale, y: min(b[1], b[3]) * scale,
                           width: abs(b[2] - b[0]) * scale, height: abs(b[3] - b[1]) * scale)
            mask = CIImage(color: .white).cropped(to: r).composited(over: CIImage(color: .black).cropped(to: nativeRect))
        case .ellipse:
            let b = m.box
            let cx = (b[0] + b[2]) / 2 * scale, cy = (b[1] + b[3]) / 2 * scale
            let rx = max(abs(b[2] - b[0]) / 2 * scale, 1), ry = max(abs(b[3] - b[1]) / 2 * scale, 1)
            mask = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: 0, y: 0), "inputRadius0": max(rx - 0.75, 0), "inputRadius1": rx + 0.75,
                "inputColor0": CIColor.white, "inputColor1": CIColor.black,
            ])!.outputImage!
                .transformed(by: CGAffineTransform(scaleX: 1, y: ry / rx).concatenating(.init(translationX: cx, y: cy)))
                .cropped(to: nativeRect)
        case .polygon:
            mask = polygonMask(m.polygon, scale: scale, native: native).cropped(to: nativeRect)
        case .image:
            if let src = sourceImage(m.maskFile), src.extent.width > 0 {
                let e = src.extent
                mask = src.transformed(by: .init(translationX: -e.minX, y: -e.minY))
                    .transformed(by: .init(scaleX: nativeRect.width / e.width, y: nativeRect.height / e.height))
                    .clampedToExtent().cropped(to: nativeRect)
            } else {
                mask = CIImage(color: .black).cropped(to: nativeRect)
            }
        }
        return mask.cropped(to: nativeRect)
    }

    /// 올가미 선택 마스크 (채운 다각형). 최대 1/2 해상도로 그리고 키운다.
    static func polygonMask(_ pts: [Double], scale: CGFloat, native: CGSize) -> CIImage {
        let rs = min(scale, 0.5)
        let w = Int((native.width * rs).rounded(.up)), h = Int((native.height * rs).rounded(.up))
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if pts.count >= 6 {
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.move(to: CGPoint(x: pts[0] * rs, y: pts[1] * rs))
            for i in stride(from: 2, to: pts.count - 1, by: 2) { ctx.addLine(to: CGPoint(x: pts[i] * rs, y: pts[i + 1] * rs)) }
            ctx.closePath()
            ctx.fillPath()
        }
        let img = CIImage(cgImage: ctx.makeImage()!)
        let k = scale / rs
        return k == 1 ? img : img.transformed(by: .init(scaleX: k, y: k))
    }

    private static var brushCache: [String: CIImage] = [:]
    private static let brushLock = NSLock()

    /// 붓질 마스크. 부드러운 마스크라 원본 해상도까지는 필요 없어서 최대 1/2 해상도로 그리고 키운다.
    /// 딱딱함(hardness)은 흐림 반경으로 낸다.
    static func brushMask(_ strokes: [MaskStroke], scale: CGFloat, native: CGSize, white: Bool = false) -> CIImage {
        let rs = min(scale, 0.5)
        let key = "\(strokes.hashValue)|\(rs)|\(white)"
        brushLock.lock(); defer { brushLock.unlock() }
        let img: CIImage
        if let hit = brushCache[key] {
            img = hit
        } else {
            let w = Int((native.width * rs).rounded(.up)), h = Int((native.height * rs).rounded(.up))
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.setFillColor(gray: white ? 1 : 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for stroke in strokes {
                let pts = stride(from: 0, to: stroke.points.count - 1, by: 2)
                    .map { CGPoint(x: stroke.points[$0] * rs, y: stroke.points[$0 + 1] * rs) }
                guard let first = pts.first else { continue }
                if let t = stroke.tip, let tip = PresetFiles.tip(t) {
                    // 가져온 붓 끝을 찍는다 (지우개는 검정 끝이 없어서 선으로)
                    if !stroke.erase {
                        PresetFiles.stamp(ctx, tip: tip, points: pts, diameter: stroke.radius * 2 * rs,
                                          spacing: stroke.spacing ?? 0.25, alpha: stroke.flow)
                        continue
                    }
                }
                // 지우개는 검정으로 덮는다. 그리기는 흐름(flow)만큼 쌓는다.
                ctx.setStrokeColor(gray: stroke.erase ? 0 : 1, alpha: stroke.erase ? 1 : stroke.flow)
                ctx.setLineWidth(stroke.radius * 2 * rs * (0.55 + 0.45 * stroke.hardness))
                ctx.beginPath()
                ctx.move(to: first)
                if pts.count == 1 { ctx.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)) }
                for p in pts.dropFirst() { ctx.addLine(to: p) }
                ctx.strokePath()
            }
            let hardness = strokes.map { $0.tip == nil ? $0.hardness : 1 }.reduce(0, +) / Double(max(strokes.count, 1))
            let avgR = strokes.map(\.radius).reduce(0, +) / Double(max(strokes.count, 1))
            var raw = CIImage(cgImage: ctx.makeImage()!)
            // 부드러운 붓일수록 더 흐린다 (평균 반지름 기준).
            let sigma = avgR * rs * (1 - hardness) * 0.45
            if sigma > 0.5 { raw = raw.blurred(sigma) }
            img = raw
            if brushCache.count > 16 { brushCache.removeAll() }
            brushCache[key] = img
        }
        let k = scale / rs
        return k == 1 ? img : img.transformed(by: .init(scaleX: k, y: k))
    }
}

/// 이미지 레이어 그림 폴더. 시험 실행은 임시 폴더를 쓴다.
enum LayerImageStore {
    /// 지금 카탈로그 (열 때 정한다). 레이어 그림·AI 마스크·LUT는 카탈로그 안 Assets 폴더에 둔다.
    static var catalogURL: URL? { didSet { cachedFolder = nil } }
    private static var cachedFolder: URL?

    static var folder: URL {
        if let f = cachedFolder { return f }
        let env = ProcessInfo.processInfo.environment
        var dir: URL
        if let c = catalogURL {
            dir = c.appendingPathComponent("Assets", isDirectory: true)
        } else if env["DUOCHROME_SNAPSHOT"] != nil || env["DUOCHROME_CATALOG_TEST"] != nil || env["DUOCHROME_SELFTEST"] != nil {
            dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("duochrome-test-layerimages")
        } else {
            dir = legacyFolder
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cachedFolder = dir
        return dir
    }

    /// 예전 레이어 그림 폴더 (옮겨 올 때만 읽는다)
    static var legacyFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Duochrome/LayerImages", isDirectory: true)
    }

    static func url(_ file: String) -> URL { folder.appendingPathComponent(file) }

    /// 파일을 복사해 넣고 이름을 돌려준다 (원본을 옮기거나 지워도 레이어가 남게).
    static func importFile(_ src: URL) throws -> String {
        let name = UUID().uuidString + "." + (src.pathExtension.isEmpty ? "png" : src.pathExtension.lowercased())
        try FileManager.default.copyItem(at: src, to: url(name))
        return name
    }

    /// 데이터(붙여넣은 그림)를 파일로 적는다.
    static func importData(_ data: Data, ext: String) throws -> String {
        let name = UUID().uuidString + "." + ext
        try data.write(to: url(name))
        return name
    }
}

/// .cube LUT 읽기 (3D만). 빨강이 가장 빨리 바뀌는 순서라 CIColorCube와 같다.
enum CubeLUT {
    private static var cache: [String: (n: Int, data: Data)] = [:]
    private static let lock = NSLock()

    static func load(_ file: String) -> (n: Int, data: Data)? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[file] { return hit }
        guard let text = try? String(contentsOf: LayerImageStore.url(file), encoding: .utf8),
              let parsed = parse(text) else { return nil }
        cache[file] = parsed
        return parsed
    }

    static func parse(_ text: String) -> (n: Int, data: Data)? {
        var n = 0
        var lo: [Float] = [0, 0, 0], hi: [Float] = [1, 1, 1]
        var values: [Float] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("TITLE") { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.first == "LUT_3D_SIZE", parts.count > 1 { n = Int(parts[1]) ?? 0; continue }
            if parts.first == "LUT_1D_SIZE" { return nil }
            if parts.first == "DOMAIN_MIN", parts.count >= 4 { lo = parts[1...3].compactMap { Float($0) }; continue }
            if parts.first == "DOMAIN_MAX", parts.count >= 4 { hi = parts[1...3].compactMap { Float($0) }; continue }
            let v = parts.compactMap { Float($0) }
            if v.count == 3 {
                // 출력 값을 0~1로 (영역이 다르면 맞춘다)
                for c in 0..<3 { values.append((v[c] - lo[c]) / max(hi[c] - lo[c], 1e-6)) }
                values.append(1)
            }
        }
        guard n >= 2, values.count == n * n * n * 4 else { return nil }
        return (n, values.withUnsafeBufferPointer { Data(buffer: $0) })
    }
}
