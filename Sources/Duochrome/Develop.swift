import CoreImage

/// Develop stage applied after RAW decoding. Order:
/// high dynamic range → tone (contrast, brightness, whites, blacks) → saturation → vignette.
///
/// Built from Core Image built-in filters for now. Things built-ins can't do, like clarity and dehaze,
/// are attached as custom Metal kernels.
enum Develop {
    /// Resolution at which wide-radius tool maps are built.
    static let guideScale: CGFloat = 1.0 / 8

    /// Full develop. `guide` is the same photo decoded at guideScale. If nil, `image` itself is at that resolution.
    static func apply(_ s: DevelopSettings, to image: CIImage, guide: CIImage?, scale: CGFloat, haze: Float) -> CIImage {
        let (out, _) = base(s, to: image, guide: guide, scale: scale, haze: haze)
        return finish(s, out, scale: scale)
    }

    /// Develop up to the layers. Also returns the 1/8 guide image passed through the same stages
    /// (layer clarity maps are built from it).
    static func base(_ s: DevelopSettings, to image: CIImage, guide: CIImage?, scale: CGFloat,
                     haze: Float) -> (CIImage, CIImage) {
        var out = image
        var g = guide ?? image
        let gs = guide == nil ? scale : guideScale

        if s.dehaze > 0 {
            (out, g) = dehaze(out, guide: g, guideScale: gs, scale: scale, amount: s.dehaze / 100, light: haze,
                              hue: s.dehazeHue, tint: s.dehazeTint)
        }
        // Clarity is wide-radius local contrast, structure is narrow-radius.
        if s.hotPixels > 0 { out = hotPixels(out, amount: s.hotPixels / 100) }
        if s.clarity != 0 {
            // Classic preserves edges less (higher eps), so it's rougher and stronger.
            let eps: Float = s.clarityMethod == 3 ? 0.05 : 0.01
            (out, g) = localContrast(out, guide: g, guideScale: gs, scale: scale,
                                     amount: s.clarity / 100, radius: 120, eps: eps, method: s.clarityMethod)
        }
        if s.structure != 0 {
            (out, g) = localContrast(out, guide: g, guideScale: gs, scale: scale,
                                     amount: s.structure / 100, radius: 12, eps: 0.002, method: s.clarityMethod)
        }
        // Highlights/shadows are local (shift whole bright/dark regions while keeping texture within). Excluded from the tone stage.
        var st = s
        if s.highlightTone != 0 || s.shadow != 0 {
            (out, g) = localTone(out, guide: g, guideScale: gs, scale: scale,
                                 highlight: s.highlightTone / 100, shadow: s.shadow / 100)
            st.highlightTone = 0
            st.shadow = 0
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

    /// Tone stage looking only at a pixel (and a small neighborhood): highlights/shadows → tone curve → saturation.
    static func tone(_ s: DevelopSettings, _ image: CIImage, scale: CGFloat) -> CIImage {
        let extent = image.extent
        var out = image
        // Highlights/shadows: push/lift luminance only, in stops (defined in docs/SLIDERS.md).
        // In develop they are applied locally in base(); this path is for per-pixel use like adjustment layers and LUT export.
        if s.highlightTone != 0 {
            out = GPU.run("highlight_curve", [out], params: [s.highlightTone / 100], extent: extent)
        }
        if s.shadow != 0 {
            out = GPU.run("shadow_curve", [out], params: [s.shadow / 100], extent: extent)
        }
        if let curve = toneCurve(s) {
            // The tone curve is applied in display gamma space. In linear space the midtones skew too dark.
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

    /// Finishing after layers: film grain, vignette.
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

    /// Edge-preserving local contrast (guided filter, He 2010). Using a guided filter instead of a blur for the base
    /// reduces halos at bright-wall / dark-sky boundaries.
    ///
    /// Fast guided filter (He 2015): coefficients a, b vary smoothly, so solve them on a small guide image and upscale,
    /// applying only at full resolution. `radius` is in source pixels.
    /// Narrow radii (structure) get too small for the guide, so solve directly at full resolution.
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

    /// Local highlights/shadows: apply two curves to an edge-preserving base luminance (80 px radius, source scale)
    /// and multiply pixels by the resulting ratio. Unlike a per-pixel curve, texture (detail contrast) within regions isn't reduced.
    static func localTone(_ img: CIImage, guide: CIImage, guideScale gs: CGFloat, scale: CGFloat,
                          highlight: Float, shadow: Float) -> (CIImage, CIImage) {
        let amount = [highlight, shadow]
        // Larger eps keeps fine texture out of the base so more texture remains (only big edges separate)
        let radius: CGFloat = 80, eps: Float = 0.03
        func direct(_ i: CIImage, _ r: CGFloat) -> CIImage {
            let e = i.extent
            let lum = GPU.run("luma_sq", [i], extent: e)
            let ab = GPU.run("guided_ab", [lum.blurred(r)], params: [eps], extent: e).blurred(r)
            return GPU.run("tone_local", [i, lum, ab], params: amount, extent: e)
        }
        let rFull = radius * scale
        if rFull <= 24 || gs == scale {
            let out = direct(img, max(rFull, 1))
            let g = gs == scale ? out : direct(guide, max(radius * gs, 1))
            return (out, g)
        }
        // Wide radius: solve coefficients on a small guide and upscale (same as clarity)
        let rg = max(radius * gs, 1)
        let lumG = GPU.run("luma_sq", [guide], extent: guide.extent)
        let ab = GPU.run("guided_ab", [lumG.blurred(rg)], params: [eps], extent: guide.extent).blurred(rg)
        let lum = GPU.run("luma_sq", [img], extent: img.extent)
        let out = GPU.run("tone_local", [img, lum, grow(ab, by: scale / gs, to: img.extent)], params: amount, extent: img.extent)
        let g = GPU.run("tone_local", [guide, lumG, ab], params: amount, extent: guide.extent)
        return (out, g)
    }

    private static func guidedContrast(_ img: CIImage, radius: CGFloat, eps: Float, amount: Float, method: Float = 0) -> CIImage {
        let e = img.extent
        let lum = GPU.run("luma_sq", [img], extent: e)
        let ab = GPU.run("guided_ab", [lum.blurred(radius)], params: [eps], extent: e).blurred(radius)
        return GPU.run("clarity_apply", [img, lum, ab], params: [amount, method], extent: e)
    }

    /// Single-pixel (hot pixel) removal: replaces only isolated pixels that differ strongly from the 3×3 median.
    static func hotPixels(_ img: CIImage, amount: Float) -> CIImage {
        let median = img.clampedToExtent().applyingFilter("CIMedianFilter").cropped(to: img.extent)
        return GPU.run("hot_pixel", [img, median], params: [0.35 - amount * 0.3], extent: img.extent)
    }

    /// Extra sharpening (unsharp mask + threshold + halo suppression). Radius in source pixels.
    static func sharpen(_ img: CIImage, _ s: DevelopSettings, scale: CGFloat) -> CIImage {
        let r = max(CGFloat(s.sharpenRadius) * scale, 0.35)
        let blurred = img.blurred(r)
        return GPU.run("usm_apply", [img, blurred],
                       params: [s.sharpenAmount / 100, s.sharpenThreshold / 255, s.sharpenHalo / 100], extent: img.extent)
    }

    /// Dark channel dehaze. The dark channel is widened with a minimum filter, then smoothed and used as transmission.
    /// The transmission map varies broadly, so it's built from an even smaller guide image.
    static func dehaze(_ img: CIImage, guide: CIImage, guideScale gs: CGFloat, scale: CGFloat,
                       amount: Float, light: Float, hue: Float = 0, tint: Float = 0) -> (CIImage, CIImage) {
        let r = max(120 * gs, 2)   // 120 px at source scale
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

    /// Film grain. Blurs coordinate-locked noise to set grain size, strongest in the midtones.
    /// Grain size is in source pixels, so the same grain shows at any zoom.
    static func grain(_ img: CIImage, amount: Float, size: Float, scale: CGFloat, type: Int = 0) -> CIImage {
        let e = img.extent
        // Types: silver is large and crisp, soft is blurrier, color grain uses different noise per channel.
        let sizeMul: CGFloat = [1, 1.6, 2.2, 1][min(max(type, 0), 3)]
        let sigma = (0.4 + CGFloat(size) * 2.5) * scale * sizeMul
        // Blurring lowers amplitude, so restore it. When grain gets smaller than a pixel (zoomed out) it's weaker to the eye too, so only that much.
        let comp = max(1, sigma * 3.5)
        let visible = min(1, sigma / 0.5)
        // A generator filter without input can't be made with applyingFilter (no input image key).
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
        // Snap to the integer pixel grid. A fractional kernel output size left one empty row at the edge.
        return out.cropped(to: out.extent.integral)
    }

    private static func grow(_ img: CIImage, by f: CGFloat, to extent: CGRect) -> CIImage {
        guard f > 1 else { return img }
        return img.clampedToExtent().transformed(by: .init(scaleX: f, y: f)).cropped(to: extent)
    }

    /// Airlight A: top dark channel values. Measured once on a small image.
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

    /// Linear value → display value for the tone curve (sRGB transfer function of Display P3)
    static func encode(_ v: Float) -> Float {
        v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    /// Combines contrast, brightness, whites, blacks, and the curves tool into one per-channel curve. nil if nothing changed.
    static func toneCurve(_ s: DevelopSettings) -> Data? {
        let levelsChanged = s.levelInBlack != 0 || s.levelInWhite != 1 || s.levelGamma != 1
            || s.levelOutBlack != 0 || s.levelOutWhite != 1
        let channelLevels = s.levelsRGB.contains { $0 != [0, 1, 1, 0, 1] }
        let baseChanged = channelLevels || s.contrast != 0 || s.filmContrast != 0 || s.brightness != 0 || s.white != 0 || s.black != 0 || levelsChanged
        guard baseChanged || !s.curves.isIdentity else { return nil }
        let n = 256, fine = 1024
        // Brightness: a gamma that keeps both ends and moves middle gray (18% linear) by exactly brightness/100 stops.
        let mid0 = encode(0.18), mid1 = encode(min(0.18 * pow(2, s.brightness / 100), 1))
        let gamma = s.brightness == 0 ? 1 : log(mid1) / log(mid0)
        // Contrast: S-curve pivoting on the moved middle gray. Slope at the pivot is 2^(contrast/100); ends and middle gray stay.
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
            // Blacks move the dark end, whites the bright end. Cubic, so the middle moves less.
            // A 4th power concentrated too much at the ends; bright areas (display 0.5–0.8) barely changed.
            x += s.black / 100 * 0.10 * pow(1 - x, 3)
            x += s.white / 100 * 0.25 * pow(x, 3)
            x = min(max(x, 0), 1)
            x = pow(x, gamma)
            x = x < pivot ? pivot * pow(x / pivot, g) : 1 - (1 - pivot) * pow((1 - x) / (1 - pivot), g)
            // Levels: stretch the input range to 0–1, shift the middle with gamma, then compress to the output range.
            if levelsChanged {
                x = min(max((x - s.levelInBlack) / max(s.levelInWhite - s.levelInBlack, 0.001), 0), 1)
                x = pow(x, 1 / max(s.levelGamma, 0.01))
                x = s.levelOutBlack + x * (s.levelOutWhite - s.levelOutBlack)
            }
            let y = lookup(rgb, x)
            // Per-channel levels, then per-channel curves
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
