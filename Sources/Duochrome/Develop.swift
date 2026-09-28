import CoreImage

/// RAW 디코딩 뒤에 거는 현상 단계. 처리 순서:
/// 하이 다이내믹 레인지 → 톤(대비·밝기·화이트·블랙) → 채도 → 비네팅.
///
/// 지금은 Core Image 내장 필터로 만든다. 클래리티·디헤이즈처럼 내장 필터로 안 되는 것은
/// 자체 Metal 커널로 따로 붙인다.
enum Develop {
    /// 넓은 반경 도구의 지도를 만드는 해상도.
    static let guideScale: CGFloat = 1.0 / 8

    /// 전체 현상. `guide`는 같은 사진을 guideScale로 디코딩한 것. nil이면 `image` 자체가 그 해상도다.
    static func apply(_ s: DevelopSettings, to image: CIImage, guide: CIImage?, scale: CGFloat, haze: Float) -> CIImage {
        let (out, _) = base(s, to: image, guide: guide, scale: scale, haze: haze)
        return finish(s, out, scale: scale)
    }

    /// 레이어 전까지의 현상. 1/8 가이드 이미지도 같은 단계를 거쳐 함께 돌려준다
    /// (레이어의 클래리티 지도를 그 위에서 만든다).
    static func base(_ s: DevelopSettings, to image: CIImage, guide: CIImage?, scale: CGFloat,
                     haze: Float) -> (CIImage, CIImage) {
        var out = image
        var g = guide ?? image
        let gs = guide == nil ? scale : guideScale

        if s.dehaze > 0 {
            (out, g) = dehaze(out, guide: g, guideScale: gs, scale: scale, amount: s.dehaze / 100, light: haze,
                              hue: s.dehazeHue, tint: s.dehazeTint)
        }
        // 클래리티는 넓은 반경, 구조는 좁은 반경의 국소 대비.
        if s.hotPixels > 0 { out = hotPixels(out, amount: s.hotPixels / 100) }
        if s.clarity != 0 {
            // 클래식은 가장자리 보존을 덜 해서(eps↑) 더 거칠고 세다.
            let eps: Float = s.clarityMethod == 3 ? 0.05 : 0.01
            (out, g) = localContrast(out, guide: g, guideScale: gs, scale: scale,
                                     amount: s.clarity / 100, radius: 120, eps: eps, method: s.clarityMethod)
        }
        if s.structure != 0 {
            (out, g) = localContrast(out, guide: g, guideScale: gs, scale: scale,
                                     amount: s.structure / 100, radius: 12, eps: 0.002, method: s.clarityMethod)
        }
        // 하이라이트는 국소로 (밝은 구역 전체를 옮기되 그 안의 질감은 남긴다). 톤 단계에서는 뺀다.
        var st = s
        if s.highlightTone != 0 {
            (out, g) = localHighlights(out, guide: g, guideScale: gs, scale: scale, amount: s.highlightTone / 100)
            st.highlightTone = 0
        }
        out = tone(st, out, scale: scale)
        var lutKey = s.color
        lutKey.luma = s.curves.luma
        out = ColorLUT.apply(lutKey, to: out)
        if guide != nil {
            g = tone(st, g, scale: gs)
            g = ColorLUT.apply(lutKey, to: g)
        } else {
            g = out
        }
        return (out, g)
    }

    /// 픽셀 하나(와 좁은 이웃)만 보는 톤 단계: 하이라이트·섀도 → 톤 곡선 → 채도.
    static func tone(_ s: DevelopSettings, _ image: CIImage, scale: CGFloat) -> CIImage {
        let extent = image.extent
        var out = image
        // 하이라이트·섀도: 휘도만 스톱 단위로 누르고 밝힌다 (정의는 docs/SLIDERS.md).
        // 현상 단계의 하이라이트는 base()에서 국소로 걸고, 여기는 조정 레이어·LUT 내보내기처럼 한 픽셀씩 볼 때.
        if s.highlightTone != 0 {
            out = GPU.run("highlight_curve", [out], params: [s.highlightTone / 100], extent: extent)
        }
        if s.shadow > 0 {
            out = GPU.run("shadow_curve", [out], params: [s.shadow / 100], extent: extent)
        }
        if let curve = toneCurve(s) {
            // 톤 곡선은 화면 감마 공간에서 건다. 선형 공간에서 걸면 가운데가 너무 어둡게 쏠린다.
            out = out.applyingFilter("CIColorCurves", parameters: [
                "inputCurvesData": curve,
                "inputCurvesDomain": CIVector(x: 0, y: 1),
                "inputColorSpace": Render.displaySpace,
            ])
        }
        if s.saturation != 0 {
            out = out.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1 + s.saturation / 100,
                kCIInputBrightnessKey: 0,
                kCIInputContrastKey: 1,
            ])
        }
        return out.cropped(to: extent)
    }

    /// 레이어 뒤 마무리: 필름 그레인, 비네팅.
    static func finish(_ s: DevelopSettings, _ image: CIImage, scale: CGFloat) -> CIImage {
        let extent = image.extent
        var out = image
        if s.sharpenAmount > 0 { out = sharpen(out, s, scale: scale) }
        if s.grainAmount > 0 {
            out = grain(out, amount: s.grainAmount / 100, size: s.grainSize / 100, scale: scale, type: Int(s.grainType))
        }
        if s.vignette != 0 {
            let r = hypot(extent.width, extent.height) / 2
            out = out.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                kCIInputRadiusKey: r,
                kCIInputIntensityKey: -s.vignette / 100,
                "inputFalloff": 0.6,
            ])
        }

        return out.cropped(to: extent)
    }

    /// 가장자리를 지키는 국소 대비 (가이디드 필터, He 2010). 흐림 대신 가이디드 필터로 기저를 잡아
    /// 밝은 벽과 어두운 하늘 경계에 헤일로가 덜 생긴다.
    ///
    /// 빠른 가이디드 필터(He 2015): 계수 a, b는 부드럽게 변하므로 작은 가이드 이미지에서 구해 키우고,
    /// 적용만 원래 해상도로 한다. `radius`는 원본 픽셀 기준.
    /// 좁은 반경(구조)은 가이드로는 너무 작아져서 원래 해상도에서 바로 구한다.
    static func localContrast(_ img: CIImage, guide: CIImage, guideScale gs: CGFloat, scale: CGFloat,
                              amount: Float, radius: CGFloat, eps: Float, method: Float = 0) -> (CIImage, CIImage) {
        let rFull = radius * scale
        if rFull <= 24 || gs == scale {
            let out = guidedContrast(img, radius: max(rFull, 1), eps: eps, amount: amount, method: method)
            let g = gs == scale ? out : guidedContrast(guide, radius: max(radius * gs, 1), eps: eps, amount: amount, method: method)
            return (out, g)
        }
        let rg = max(radius * gs, 1)
        let lumG = GPU.run("luma_sq", [guide], extent: guide.extent)
        let ab = GPU.run("guided_ab", [lumG.blurred(rg)], params: [eps], extent: guide.extent).blurred(rg)
        let lum = GPU.run("luma_sq", [img], extent: img.extent)
        let out = GPU.run("clarity_apply", [img, lum, grow(ab, by: scale / gs, to: img.extent)],
                          params: [amount, method], extent: img.extent)
        let g = GPU.run("clarity_apply", [guide, lumG, ab], params: [amount, method], extent: guide.extent)
        return (out, g)
    }

    /// 국소 하이라이트: 가장자리를 지키는 기저 밝기(반경 80픽셀, 원본 기준)에 하이라이트 곡선을 걸고
    /// 그 배율을 픽셀에 곱한다. 한 픽셀씩 거는 곡선과 달리 밝은 구역 안의 질감(세부 대비)이 줄지 않는다.
    static func localHighlights(_ img: CIImage, guide: CIImage, guideScale gs: CGFloat, scale: CGFloat,
                                amount: Float) -> (CIImage, CIImage) {
        // eps가 크면 잔 질감은 기저에 덜 들어가 질감이 더 남는다 (큰 경계만 가른다)
        let radius: CGFloat = 80, eps: Float = 0.03
        func direct(_ i: CIImage, _ r: CGFloat) -> CIImage {
            let e = i.extent
            let lum = GPU.run("luma_sq", [i], extent: e)
            let ab = GPU.run("guided_ab", [lum.blurred(r)], params: [eps], extent: e).blurred(r)
            return GPU.run("highlight_local", [i, lum, ab], params: [amount], extent: e)
        }
        let rFull = radius * scale
        if rFull <= 24 || gs == scale {
            let out = direct(img, max(rFull, 1))
            let g = gs == scale ? out : direct(guide, max(radius * gs, 1))
            return (out, g)
        }
        // 넓은 반경: 작은 가이드에서 계수를 구해 키운다 (클래리티와 같은 방식)
        let rg = max(radius * gs, 1)
        let lumG = GPU.run("luma_sq", [guide], extent: guide.extent)
        let ab = GPU.run("guided_ab", [lumG.blurred(rg)], params: [eps], extent: guide.extent).blurred(rg)
        let lum = GPU.run("luma_sq", [img], extent: img.extent)
        let out = GPU.run("highlight_local", [img, lum, grow(ab, by: scale / gs, to: img.extent)], params: [amount], extent: img.extent)
        let g = GPU.run("highlight_local", [guide, lumG, ab], params: [amount], extent: guide.extent)
        return (out, g)
    }

    private static func guidedContrast(_ img: CIImage, radius: CGFloat, eps: Float, amount: Float, method: Float = 0) -> CIImage {
        let e = img.extent
        let lum = GPU.run("luma_sq", [img], extent: e)
        let ab = GPU.run("guided_ab", [lum.blurred(radius)], params: [eps], extent: e).blurred(radius)
        return GPU.run("clarity_apply", [img, lum, ab], params: [amount, method], extent: e)
    }

    /// 단일 픽셀(핫 픽셀) 제거: 3×3 중간값과 크게 다른 외톨이 픽셀만 중간값으로 바꾼다.
    static func hotPixels(_ img: CIImage, amount: Float) -> CIImage {
        let median = img.clampedToExtent().applyingFilter("CIMedianFilter").cropped(to: img.extent)
        return GPU.run("hot_pixel", [img, median], params: [0.35 - amount * 0.3], extent: img.extent)
    }

    /// 추가 샤프닝 (언샤프 마스크 + 임계값 + 헤일로 억제). 반경은 원본 픽셀 기준.
    static func sharpen(_ img: CIImage, _ s: DevelopSettings, scale: CGFloat) -> CIImage {
        let r = max(CGFloat(s.sharpenRadius) * scale, 0.35)
        let blurred = img.blurred(r)
        return GPU.run("usm_apply", [img, blurred],
                       params: [s.sharpenAmount / 100, s.sharpenThreshold / 255, s.sharpenHalo / 100], extent: img.extent)
    }

    /// 다크 채널 디헤이즈. 다크 채널을 최솟값 필터로 넓힌 뒤 부드럽게 해 투과율로 쓴다.
    /// 투과율 지도는 넓게 변하는 값이라 가이드 이미지를 더 줄여서 만든다.
    static func dehaze(_ img: CIImage, guide: CIImage, guideScale gs: CGFloat, scale: CGFloat,
                       amount: Float, light: Float, hue: Float = 0, tint: Float = 0) -> (CIImage, CIImage) {
        let r = max(120 * gs, 2)   // 원본 기준 120픽셀
        let f = max(1, (r / 8).rounded(.down))
        let small = shrink(guide, by: f)
        let dark = GPU.run("dark_channel", [small], extent: small.extent)
            .clampedToExtent()
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: r / f])
            .cropped(to: small.extent)
            .blurred(r / f)
        let g = GPU.run("dehaze_apply", [guide, grow(dark, by: f, to: guide.extent)],
                        params: [amount, light, hue, tint], extent: guide.extent)
        if gs == scale { return (g, g) }
        let out = GPU.run("dehaze_apply", [img, grow(dark, by: f * scale / gs, to: img.extent)],
                          params: [amount, light, hue, tint], extent: img.extent)
        return (out, g)
    }

    /// 필름 그레인. 좌표에 묶인 난수를 흐려 알갱이 크기를 만들고, 중간 톤에 가장 세게 건다.
    /// 알갱이 크기는 원본 픽셀 기준이라 확대 배율이 바뀌어도 같은 알갱이가 보인다.
    static func grain(_ img: CIImage, amount: Float, size: Float, scale: CGFloat, type: Int = 0) -> CIImage {
        let e = img.extent
        // 종류: 은염은 크고 또렷하게, 부드럽게는 더 흐리게, 색 입자는 채널마다 다른 난수.
        let sizeMul: CGFloat = [1, 1.6, 2.2, 1][min(max(type, 0), 3)]
        let sigma = (0.4 + CGFloat(size) * 2.5) * scale * sizeMul
        // 흐리면 진폭이 줄어드니 되살린다. 알갱이가 한 픽셀보다 작아지면(축소 보기) 눈에도 약해지므로 그만큼만.
        let comp = max(1, sigma * 3.5)
        let visible = min(1, sigma / 0.5)
        // 입력이 없는 생성 필터라 applyingFilter로 만들면 안 된다 (입력 이미지 키가 없다).
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .cropped(to: e.insetBy(dx: -8, dy: -8))
            .blurred(max(sigma, 0.01))
            .cropped(to: e)
        let strength: Float = [1, 1.3, 0.8, 1][min(max(type, 0), 3)]
        return GPU.run("grain_apply", [img, noise], params: [amount * Float(comp * visible) * 0.6 * strength, type == 3 ? 1 : 0], extent: e)
    }

    private static func shrink(_ img: CIImage, by f: CGFloat) -> CIImage {
        guard f > 1 else { return img }
        let out = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 1 / f, kCIInputAspectRatioKey: 1])
        // 정수 픽셀 격자에 맞춘다. 커널 출력 크기가 소수이면 가장자리 한 줄이 비었다.
        return out.cropped(to: out.extent.integral)
    }

    private static func grow(_ img: CIImage, by f: CGFloat, to extent: CGRect) -> CIImage {
        guard f > 1 else { return img }
        return img.clampedToExtent().transformed(by: .init(scaleX: f, y: f)).cropped(to: extent)
    }

    /// 대기광 A: 다크 채널 상위 값. 작은 이미지에서 한 번만 잰다.
    static func estimateHazeLight(_ small: CIImage) -> Float {
        let dark = GPU.run("dark_channel", [small], extent: small.extent)
        let hist = HistogramData.compute(dark, context: Render.context, space: Render.displaySpace)
        let total = hist.r.reduce(0, +)
        var acc: Float = 0
        for i in stride(from: 255, through: 0, by: -1) {
            acc += hist.r[i]
            if acc >= total * 0.001 { return max(Float(i) / 255, 0.5) }
        }
        return 0.9
    }

    /// 선형 값 → 톤 곡선을 거는 화면 값 (Display P3의 sRGB 전달 함수)
    static func encode(_ v: Float) -> Float {
        v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    /// 대비·밝기·화이트·블랙과 커브 도구를 채널별 곡선 하나로 합친다. 아무것도 안 바뀌었으면 nil.
    static func toneCurve(_ s: DevelopSettings) -> Data? {
        let levelsChanged = s.levelInBlack != 0 || s.levelInWhite != 1 || s.levelGamma != 1
            || s.levelOutBlack != 0 || s.levelOutWhite != 1
        let channelLevels = s.levelsRGB.contains { $0 != [0, 1, 1, 0, 1] }
        let baseChanged = channelLevels || s.contrast != 0 || s.filmContrast != 0 || s.brightness != 0 || s.white != 0 || s.black != 0 || levelsChanged
        guard baseChanged || !s.curves.isIdentity else { return nil }
        let n = 256, fine = 1024
        // 밝기: 양끝은 두고 중간 회색(선형 18%)을 정확히 밝기/100 스톱 옮기는 감마.
        let mid0 = encode(0.18), mid1 = encode(min(0.18 * pow(2, s.brightness / 100), 1))
        let gamma = s.brightness == 0 ? 1 : log(mid1) / log(mid0)
        // 대비: 옮긴 중간 회색을 축으로 한 S자 곡선. 축의 기울기가 2^(대비/100)배, 양끝과 중간 회색은 그대로.
        let g = pow(2, (s.contrast + s.filmContrast) / 100)
        let pivot = mid1
        let rgb = s.curves.rgb.sample(fine)
        let chan = [s.curves.red.sample(fine), s.curves.green.sample(fine), s.curves.blue.sample(fine)]

        func lookup(_ table: [Float], _ x: Float) -> Float {
            let f = min(max(x, 0), 1) * Float(fine - 1)
            let i = Int(f), j = min(i + 1, fine - 1), t = f - Float(i)
            return table[i] * (1 - t) + table[j] * t
        }

        var values = [Float]()
        values.reserveCapacity(n * 3)
        for i in 0..<n {
            var x = Float(i) / Float(n - 1)
            // 블랙은 어두운 쪽, 화이트는 밝은 쪽을 움직인다. 세제곱이라 가운데는 덜 움직인다.
            // 4제곱은 너무 끝에만 몰려 밝은 부분(화면 값 0.5~0.8)이 거의 안 변했다.
            x += s.black / 100 * 0.10 * pow(1 - x, 3)
            x += s.white / 100 * 0.25 * pow(x, 3)
            x = min(max(x, 0), 1)
            x = pow(x, gamma)
            x = x < pivot ? pivot * pow(x / pivot, g) : 1 - (1 - pivot) * pow((1 - x) / (1 - pivot), g)
            // 레벨: 입력 범위를 0~1로 펴고, 감마로 중간을 옮긴 뒤, 출력 범위로 줄인다.
            if levelsChanged {
                x = min(max((x - s.levelInBlack) / max(s.levelInWhite - s.levelInBlack, 0.001), 0), 1)
                x = pow(x, 1 / max(s.levelGamma, 0.01))
                x = s.levelOutBlack + x * (s.levelOutWhite - s.levelOutBlack)
            }
            let y = lookup(rgb, x)
            // 채널별 레벨 뒤 채널별 커브
            var out3 = [Float]()
            for c in 0..<3 {
                var v = y
                let l = s.levelsRGB.indices.contains(c) ? s.levelsRGB[c] : [0, 1, 1, 0, 1]
                if l != [0, 1, 1, 0, 1] {
                    v = min(max((v - l[0]) / max(l[1] - l[0], 0.001), 0), 1)
                    v = pow(v, 1 / max(l[2], 0.01))
                    v = l[3] + v * (l[4] - l[3])
                }
                out3.append(lookup(chan[c], v))
            }
            values += out3
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
