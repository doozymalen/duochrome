import CoreImage

/// 필터 갤러리 47가지 (예술 효과 15, 브러시 획 8, 왜곡 3, 스케치 14, 스타일화 1, 텍스처 6)를
/// 코어 이미지 조합으로 흉내 낸다. 모양은 근사치다. 이미 있던 수채화·목탄·텍스처화·유리·하프톤은 그대로 쓴다.
extension Effects {
    // MARK: 도움 함수

    static func noise(_ e: CGRect, scale: CGFloat, seed: CGFloat = 0, mono: Bool = true) -> CIImage {
        var n = CIFilter(name: "CIRandomGenerator")!.outputImage!.transformed(by: .init(translationX: seed * 97, y: seed * 53))
        if scale > 1.01 { n = n.transformed(by: .init(scaleX: scale, y: scale)) }
        if mono { n = n.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0)]) }
        return n.cropped(to: e)
    }
    static func edgesOf(_ i: CIImage, _ k: CGFloat = 2) -> CIImage {
        gray(i).applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: k]).cropped(to: i.extent)
    }
    static func mul(_ a: CIImage, _ b: CIImage) -> CIImage { a.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: b]).cropped(to: b.extent) }
    static func screen(_ a: CIImage, _ b: CIImage) -> CIImage { a.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: b]).cropped(to: b.extent) }
    static func overlay(_ a: CIImage, _ b: CIImage) -> CIImage { a.applyingFilter("CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: b]).cropped(to: b.extent) }
    static func mixImg(_ a: CIImage, _ b: CIImage, _ t: Double) -> CIImage {
        b.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: a, kCIInputTimeKey: 1 - t]).cropped(to: a.extent)
    }
    static func kuwa(_ i: CIImage, _ r: Double, _ s: CGFloat) -> CIImage {
        let k = max(min(s, 1), 0.25)
        return general(kuwaharaK, i.transformed(by: .init(scaleX: k, y: k)), pad: 7, [r]).transformed(by: .init(scaleX: 1 / k, y: 1 / k)).cropped(to: i.extent)
    }
    static func thresholdImg(_ i: CIImage, _ t: Double) -> CIImage { gray(i).applyingFilter("CIColorThreshold", parameters: ["inputThreshold": t]) }
    static func motion(_ i: CIImage, _ r: Double, _ deg: Double) -> CIImage {
        i.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: max(r, 0.5), kCIInputAngleKey: deg * .pi / 180]).cropped(to: i.extent)
    }
    static func embossGray(_ i: CIImage, _ strength: Double = 1) -> CIImage {
        let w = [-2, -1, 0, -1, 0, 1, 0, 1, 2].map { $0 * strength }
        return gray(i).clampedToExtent().applyingFilter("CIConvolution3X3", parameters: [
            "inputWeights": CIVector(values: w.map { CGFloat($0) }, count: 9), "inputBias": 0.5]).cropped(to: i.extent)
    }
    static func tint(_ g: CIImage, dark: CIColor, light: CIColor) -> CIImage {
        g.applyingFilter("CIFalseColor", parameters: ["inputColor0": dark, "inputColor1": light])
    }

    static func P(_ key: String, _ title: String, _ r: ClosedRange<Double>, _ d: Double, px: Bool = false) -> EffectParam {
        EffectParam(key: key, title: title, range: r, def: d, pixels: px, unit: px ? "px" : "")
    }

    static let galleryFilters: [EffectSpec] = [
        // 예술 효과
        EffectSpec(kind: "g_coloredPencil", title: "색연필 (예술 효과)", category: .gallery, params: [P("width", "연필 굵기", 1...10, 3)], gamma: true) { i, v, _ in
            let g = gray(i), inv = g.applyingFilter("CIColorInvert").blurred(CGFloat(v("width")))
            let pencil = inv.applyingFilter("CIColorDodgeBlendMode", parameters: [kCIInputBackgroundImageKey: g]).cropped(to: i.extent)
            return mul(mixImg(i, CIImage(color: .white).cropped(to: i.extent), 0.4), pencil)
        },
        EffectSpec(kind: "g_cutout", title: "오려내기 (예술 효과)", category: .gallery, params: [P("levels", "단계 수", 2...8, 6)], gamma: true) { i, v, s in
            kuwa(i, 3, s).applyingFilter("CIColorPosterize", parameters: ["inputLevels": v("levels")])
        },
        EffectSpec(kind: "g_dryBrush", title: "드라이 브러시 (예술 효과)", category: .gallery, params: [P("size", "붓 크기", 1...6, 2)], gamma: true) { i, v, s in
            let p = kuwa(i, v("size"), s)
            return p.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 2, kCIInputIntensityKey: 0.8]).cropped(to: i.extent)
        },
        EffectSpec(kind: "g_filmGrain", title: "필름 그레인 (예술 효과)", category: .gallery, params: [P("grain", "그레인", 0...1, 0.35), P("highlight", "밝은 영역", 0...1, 0.2)], gamma: true) { i, v, s in
            let n = noise(i.extent, scale: max(s * 1.5, 1)).applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 0.6 + v("grain")])
            let g = mixImg(i, overlay(n, i), v("grain"))
            return g.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 1 + v("highlight")])
        },
        EffectSpec(kind: "g_fresco", title: "프레스코 (예술 효과)", category: .gallery, params: [], gamma: true) { i, _, s in
            let p = kuwa(i, 3, s).applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.35])
            return mul(edgesOf(p, 3).applyingFilter("CIColorInvert"), p)
        },
        EffectSpec(kind: "g_neonGlow", title: "네온 광선 (예술 효과)", category: .gallery, params: [P("size", "광선 크기", 1...30, 8, px: true)], gamma: true) { i, v, _ in
            let e = edgesOf(i, 4)
            let glow = tint(e, dark: .black, light: CIColor(red: 0.3, green: 0.9, blue: 1)).clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: v("size")]).cropped(to: i.extent)
            return screen(glow, gray(i).applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.25]))
        },
        EffectSpec(kind: "g_paintDaubs", title: "페인트 바르기 (예술 효과)", category: .gallery, params: [P("size", "붓 크기", 1...6, 4)], gamma: true) { i, v, s in
            kuwa(i, v("size"), s).applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 3, kCIInputIntensityKey: 1.2]).cropped(to: i.extent)
        },
        EffectSpec(kind: "g_paletteKnife", title: "팔레트 나이프 (예술 효과)", category: .gallery, params: [], gamma: true) { i, _, s in
            kuwa(i, 5, s).applyingFilter("CIColorPosterize", parameters: ["inputLevels": 10])
        },
        EffectSpec(kind: "g_plasticWrap", title: "비닐 랩 (예술 효과)", category: .gallery, params: [P("amount", "광택", 0...1, 0.6)], gamma: true) { i, v, _ in
            let relief = embossGray(i.blurred(3), 3).applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.5, y: 0), "inputPoint2": CIVector(x: 0.6, y: 0.2),
                "inputPoint3": CIVector(x: 0.75, y: 0.8), "inputPoint4": CIVector(x: 1, y: 1)])
            return mixImg(i, screen(relief, i), v("amount"))
        },
        EffectSpec(kind: "g_posterEdges", title: "포스터 가장자리 (예술 효과)", category: .gallery, params: [P("levels", "포스터화", 2...10, 6)], gamma: true) { i, v, _ in
            mul(edgesOf(i, 3).applyingFilter("CIColorInvert").applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 2]),
                i.applyingFilter("CIColorPosterize", parameters: ["inputLevels": v("levels")]))
        },
        EffectSpec(kind: "g_roughPastels", title: "거친 파스텔 (예술 효과)", category: .gallery, params: [], gamma: true) { i, _, s in
            let strokes = motion(noise(i.extent, scale: max(s * 2, 1)), 12 * Double(s), 45)
            return overlay(strokes.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.5]), kuwa(i, 2, s))
        },
        EffectSpec(kind: "g_smudgeStick", title: "문지르기 스틱 (예술 효과)", category: .gallery, params: [], gamma: true) { i, _, s in
            motion(i, 6 * Double(s), 45).applyingFilter("CIHighlightShadowAdjust", parameters: ["inputShadowAmount": -0.4])
        },
        EffectSpec(kind: "g_sponge", title: "스펀지 (예술 효과)", category: .gallery, params: [], gamma: true) { i, _, s in
            let sp = noise(i.extent, scale: max(s * 3, 1)).blurred(1.5).applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.55])
            return mixImg(kuwa(i, 2, s), mul(sp.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: 0.6]), kuwa(i, 2, s)), 0.5)
        },
        EffectSpec(kind: "g_underpainting", title: "언더페인팅 (예술 효과)", category: .gallery, params: [], gamma: true) { i, _, s in
            let base = i.blurred(6 * s)
            return overlay(clouds(i.extent, scale: s * 0.08, seed: 3).applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 0.5]), mixImg(i, base, 0.6))
        },
        // 브러시 획
        EffectSpec(kind: "g_accentedEdges", title: "강조된 가장자리 (브러시 획)", category: .gallery, params: [P("bright", "가장자리 밝기", 0...1, 0.5)], gamma: true) { i, v, s in
            let p = kuwa(i, 2, s)
            return mixImg(p, screen(edgesOf(p, 3), p), v("bright"))
        },
        EffectSpec(kind: "g_angledStrokes", title: "각진 획 (브러시 획)", category: .gallery, params: [P("length", "획 길이", 2...40, 12, px: true)], gamma: true) { i, v, _ in
            let a = motion(i, v("length"), 45), b = motion(i, v("length"), -45)
            let m = gray(i).applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.5])
            return a.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: b, kCIInputMaskImageKey: m]).cropped(to: i.extent)
        },
        EffectSpec(kind: "g_crosshatch", title: "크로스 해치 (브러시 획)", category: .gallery, params: [P("strength", "세기", 0...1, 0.6)], gamma: true) { i, v, s in
            let n = noise(i.extent, scale: max(s, 1))
            let h1 = motion(n, 10 * Double(s), 45), h2 = motion(n, 10 * Double(s), -45)
            let hatch = mul(h1.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 3]), h2.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 3]))
            return mixImg(i, mul(mixImg(hatch, CIImage(color: .white).cropped(to: i.extent), 0.5), i), v("strength"))
        },
        EffectSpec(kind: "g_darkStrokes", title: "어두운 획 (브러시 획)", category: .gallery, params: [], gamma: true) { i, _, s in
            let dark = motion(i, 8 * Double(s), -45).applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.25, kCIInputContrastKey: 1.3])
            let light = motion(i, 8 * Double(s), 45)
            let m = gray(i).applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.45])
            return light.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: dark, kCIInputMaskImageKey: m]).cropped(to: i.extent)
        },
        EffectSpec(kind: "g_inkOutlines", title: "잉크 윤곽선 (브러시 획)", category: .gallery, params: [], gamma: true) { i, _, _ in
            mul(edgesOf(i, 4).applyingFilter("CIColorInvert").applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 2.5]),
                i.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.2]))
        },
        EffectSpec(kind: "g_spatter", title: "뿌리기 (브러시 획)", category: .gallery, params: [P("radius", "뿌림 반경", 1...25, 8, px: true)], gamma: true) { i, v, s in
            let n = noise(i.extent, scale: max(s, 1), mono: false).applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.8]).cropped(to: i.extent)
            return i.clampedToExtent().applyingFilter("CIDisplacementDistortion", parameters: ["inputDisplacementImage": n, kCIInputScaleKey: v("radius") * 2]).cropped(to: i.extent)
        },
        EffectSpec(kind: "g_sprayedStrokes", title: "스프레이 획 (브러시 획)", category: .gallery, params: [P("length", "획 길이", 2...40, 14, px: true)], gamma: true) { i, v, s in
            let n = motion(noise(i.extent, scale: max(s, 1), mono: false), v("length"), 30)
            return i.clampedToExtent().applyingFilter("CIDisplacementDistortion", parameters: ["inputDisplacementImage": n, kCIInputScaleKey: v("length")]).cropped(to: i.extent)
        },
        EffectSpec(kind: "g_sumiE", title: "수묵화 (브러시 획)", category: .gallery, params: [], gamma: true) { i, _, s in
            gray(kuwa(i, 3, s)).applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.8, kCIInputBrightnessKey: 0.05]).blurred(1 * s)
        },
        // 왜곡
        EffectSpec(kind: "g_diffuseGlow", title: "확산 광선 (왜곡)", category: .gallery, params: [P("glow", "광선 양", 0...1, 0.5)], gamma: true) { i, v, s in
            let hi = gray(i).applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.65]).clampedToExtent().blurred(12 * s).cropped(to: i.extent)
            let grain = overlay(noise(i.extent, scale: 1).applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 0.3]), i)
            return screen(hi.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: CGFloat(v("glow")), y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: CGFloat(v("glow")), z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(v("glow")), w: 0)]), grain)
        },
        EffectSpec(kind: "g_oceanRipple", title: "바다 물결 (왜곡)", category: .gallery, params: [P("size", "물결 크기", 2...60, 12, px: true), P("amount", "세기", 0...40, 10, px: true)], gamma: true) { i, v, s in
            let tex = clouds(i.extent, scale: CGFloat(0.35 / max(v("size"), 1)), seed: 7)
            return i.clampedToExtent().applyingFilter("CIDisplacementDistortion", parameters: ["inputDisplacementImage": tex, kCIInputScaleKey: v("amount") * 2]).cropped(to: i.extent)
        },
        // 스케치
        EffectSpec(kind: "g_basRelief", title: "저부조 (스케치)", category: .gallery, params: [P("detail", "세부", 0.5...4, 2)], gamma: true) { i, v, s in
            tint(embossGray(i.blurred(1.5 * s), v("detail")), dark: CIColor(red: 0.15, green: 0.13, blue: 0.12), light: CIColor(red: 0.95, green: 0.93, blue: 0.9))
        },
        EffectSpec(kind: "g_chalkCharcoal", title: "분필과 목탄 (스케치)", category: .gallery, params: [], gamma: true) { i, _, s in
            let strokes = motion(noise(i.extent, scale: max(s, 1)), 8 * Double(s), 45)
            let g = gray(i)
            let charcoal = mul(strokes.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 2]), g.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.35]))
            return mixImg(CIImage(color: CIColor(red: 0.55, green: 0.55, blue: 0.55)).cropped(to: i.extent), screen(g.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.7]), charcoal), 0.8)
        },
        EffectSpec(kind: "g_chrome", title: "크롬 (스케치)", category: .gallery, params: [P("smooth", "매끄럽게", 1...20, 6, px: true)], gamma: true) { i, v, _ in
            gray(i).blurred(CGFloat(v("smooth"))).applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0.2), "inputPoint1": CIVector(x: 0.25, y: 0.9), "inputPoint2": CIVector(x: 0.5, y: 0.1),
                "inputPoint3": CIVector(x: 0.75, y: 0.95), "inputPoint4": CIVector(x: 1, y: 0.3)]).cropped(to: i.extent)
        },
        EffectSpec(kind: "g_conteCrayon", title: "콩테 크레용 (스케치)", category: .gallery, params: [], gamma: true) { i, _, s in
            let g = gray(i).applyingFilter("CIColorPosterize", parameters: ["inputLevels": 4])
            let paper = overlay(noise(i.extent, scale: max(s * 2, 1)).applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 0.5]), g)
            return tint(paper, dark: CIColor(red: 0.3, green: 0.12, blue: 0.08), light: CIColor(red: 0.93, green: 0.88, blue: 0.8))
        },
        EffectSpec(kind: "g_graphicPen", title: "그래픽 펜 (스케치)", category: .gallery, params: [P("balance", "명암 균형", 0.2...0.8, 0.5)], gamma: true) { i, v, s in
            let lines = motion(noise(i.extent, scale: max(s, 1)), 10 * Double(s), 45)
            let mixd = gray(i).applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: lines.applyingFilter("CIColorMatrix", parameters: ["inputBiasVector": CIVector(x: -0.5, y: -0.5, z: -0.5, w: 0)])]).cropped(to: i.extent)
            return mixd.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": v("balance")])
        },
        EffectSpec(kind: "g_halftonePattern", title: "하프톤 패턴 (스케치)", category: .gallery, params: [P("size", "크기", 2...20, 6, px: true)], gamma: true) { i, v, _ in
            gray(i).applyingFilter("CILineScreen", parameters: [kCIInputCenterKey: CIVector(x: 0, y: 0), kCIInputWidthKey: v("size"), kCIInputAngleKey: 0, kCIInputSharpnessKey: 0.7]).cropped(to: i.extent)
        },
        EffectSpec(kind: "g_notePaper", title: "편지지 (스케치)", category: .gallery, params: [], gamma: true) { i, _, s in
            let t = thresholdImg(i.blurred(1.5 * s), 0.5)
            let paper = noise(i.extent, scale: max(s * 2, 1)).blurred(1)
            return tint(embossGray(overlay(paper.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 0.3]), t), 1.5), dark: CIColor(red: 0.6, green: 0.6, blue: 0.58), light: CIColor(red: 0.98, green: 0.97, blue: 0.94))
        },
        EffectSpec(kind: "g_photocopy", title: "복사 (스케치)", category: .gallery, params: [P("detail", "세부", 1...20, 6, px: true)], gamma: true) { i, v, _ in
            let g = gray(i)
            let hp = g.applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: g.blurred(CGFloat(v("detail")))]).cropped(to: i.extent)
            return hp.applyingFilter("CIColorInvert").applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.97])
        },
        EffectSpec(kind: "g_plaster", title: "석고 (스케치)", category: .gallery, params: [], gamma: true) { i, _, s in
            tint(embossGray(thresholdImg(i, 0.5).blurred(3 * s), 3), dark: CIColor(red: 0.35, green: 0.35, blue: 0.35), light: CIColor(red: 0.96, green: 0.96, blue: 0.95))
        },
        EffectSpec(kind: "g_reticulation", title: "망사 효과 (스케치)", category: .gallery, params: [P("density", "밀도", 0...1, 0.5)], gamma: true) { i, v, s in
            let n = noise(i.extent, scale: max(s, 1)).applyingFilter("CIColorMatrix", parameters: ["inputBiasVector": CIVector(x: -0.5, y: -0.5, z: -0.5, w: 0)])
            let a = gray(i).applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: n.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: v("density")])]).cropped(to: i.extent)
            return a.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.5])
        },
        EffectSpec(kind: "g_stamp", title: "도장 (스케치)", category: .gallery, params: [P("balance", "명암 균형", 0.2...0.8, 0.5), P("smooth", "매끄럽게", 0...10, 3, px: true)], gamma: true) { i, v, _ in
            thresholdImg(i.blurred(CGFloat(v("smooth"))), v("balance"))
        },
        EffectSpec(kind: "g_tornEdges", title: "가장자리 찢기 (스케치)", category: .gallery, params: [], gamma: true) { i, _, s in
            let n = noise(i.extent, scale: max(s * 2, 1), mono: false)
            let t = thresholdImg(i.blurred(2 * s), 0.5)
            return t.clampedToExtent().applyingFilter("CIDisplacementDistortion", parameters: ["inputDisplacementImage": n, kCIInputScaleKey: 8 * Double(s)]).cropped(to: i.extent)
        },
        EffectSpec(kind: "g_waterPaper", title: "물 종이 (스케치)", category: .gallery, params: [], gamma: true) { i, _, s in
            let fibers = motion(noise(i.extent, scale: max(s, 1)), 6 * Double(s), 80)
            return overlay(fibers.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 0.6]), i.blurred(2 * s).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.8]))
        },
        // 스타일화
        EffectSpec(kind: "g_glowingEdges", title: "가장자리 광선 (스타일화)", category: .gallery, params: [P("width", "가장자리 폭", 1...8, 2)], gamma: true) { i, v, _ in
            let e = i.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: v("width") * 2]).cropped(to: i.extent)
            return screen(e.clampedToExtent().blurred(2).cropped(to: i.extent), e)
        },
        // 텍스처
        EffectSpec(kind: "g_craquelure", title: "균열 (텍스처)", category: .gallery, params: [P("size", "조각 크기", 5...80, 25, px: true)], gamma: true) { i, v, _ in
            let cells = i.applyingFilter("CICrystallize", parameters: [kCIInputRadiusKey: v("size"), kCIInputCenterKey: CIVector(x: 0, y: 0)]).cropped(to: i.extent)
            let cracks = edgesOf(cells, 6).applyingFilter("CIColorInvert")
            return mul(cracks, overlay(embossGray(cells, 0.7), i))
        },
        EffectSpec(kind: "g_grain", title: "그레인 (텍스처)", category: .gallery, params: [P("amount", "세기", 0...1, 0.4)], gamma: true) { i, v, s in
            mixImg(i, overlay(noise(i.extent, scale: max(s, 1), mono: false), i), v("amount"))
        },
        EffectSpec(kind: "g_mosaicTiles", title: "모자이크 타일 (텍스처)", category: .gallery, params: [P("size", "타일 크기", 4...60, 16, px: true)], gamma: true) { i, v, _ in
            let tiles = i.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: v("size"), kCIInputCenterKey: CIVector(x: 0, y: 0)]).cropped(to: i.extent)
            return mul(edgesOf(tiles, 8).applyingFilter("CIColorInvert"), mixImg(tiles, i, 0.3))
        },
        EffectSpec(kind: "g_patchwork", title: "패치워크 (텍스처)", category: .gallery, params: [P("size", "칸 크기", 4...40, 10, px: true)], gamma: true) { i, v, _ in
            let tiles = i.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: v("size"), kCIInputCenterKey: CIVector(x: 0, y: 0)]).cropped(to: i.extent)
            return overlay(embossGray(tiles, 1.5), tiles)
        },
        EffectSpec(kind: "g_stainedGlass", title: "스테인드 글라스 (텍스처)", category: .gallery, params: [P("size", "조각 크기", 5...80, 20, px: true)], gamma: true) { i, v, _ in
            let cells = i.applyingFilter("CICrystallize", parameters: [kCIInputRadiusKey: v("size"), kCIInputCenterKey: CIVector(x: 0, y: 0)]).cropped(to: i.extent)
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.3])
            return mul(edgesOf(cells, 10).applyingFilter("CIColorInvert").applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 3]), cells)
        },
    ]
}
