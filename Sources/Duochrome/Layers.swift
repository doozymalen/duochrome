import CoreImage

/// Values an adjustment layer changes. Develop and color adjustment layers merged into one.
/// All zeros means "unchanged".
struct LocalAdjust: Equatable, Codable {
    /// Whether any filter (blur, sharpen, etc.) is on
    var hasFilter: Bool { blur > 0 || motionBlur > 0 || highPass > 0 || noise > 0 || median > 0 || sharpen > 0 || (skinSmooth ?? 0) > 0 }
    var exposure: Float = 0        // EV
    var contrast: Float = 0        // -100~100
    var brightness: Float = 0
    var saturation: Float = 0
    var highlight: Float = 0       // old value: 0–100 (higher recovers more)
    var highlights: Float? = nil   // -100–100: + brightens, - recovers
    /// Highlights value used for display and math (same as DevelopSettings.highlightTone)
    var highlightTone: Float {
        get { (highlights ?? 0) - highlight }
        set { highlights = newValue; highlight = 0 }
    }
    var shadow: Float = 0
    var clarity: Float = 0         // -100~100
    var dehaze: Float = 0          // 0~100
    var temperature: Float = 0     // -100 cooler – 100 warmer
    var tint: Float = 0            // -100 green – 100 magenta
    // color adjustments
    var vibrance: Float = 0        // vibrance -100–100
    var hue: Float = 0             // hue rotation -180–180°
    var filterHue: Float = 35      // photo filter hue (35° = warming filter 85)
    var filterDensity: Float = 0   // photo filter density 0–100
    var invert: Float = 0          // 1 inverts
    var posterize: Float = 0       // 0 off, 2–32 levels
    var threshold: Float = 0       // 0 off, 1–255
    /// Gradient map: empty = off. Dark color RGB + light color RGB (0–1, display values)
    var gradientMap: [Float] = []
    /// Multi-color gradient map (position, midpoint, r, g, b repeated). Used instead of gradientMap when set
    var gradientStops: [Float]? = nil
    /// Channel mixer: empty = off. 3×3 (rows: output red/green/blue, columns: input red/green/blue)
    var mixer: [Float] = []
    // Filters (radii in source pixels)
    var blur: Float = 0            // Gaussian blur
    var motionBlur: Float = 0      // motion blur distance
    var motionAngle: Float = 0     // motion blur angle (°)
    var highPass: Float = 0        // High pass radius (0 off). Blended with overlay for frequency separation retouching
    var noise: Float = 0           // add noise 0–100
    var median: Float = 0          // median (dust & scratches) 0–5
    var sharpen: Float = 0         // sharpen 0–300
    /// Skin smoothing 0–100: evens out blotches, keeps fine texture like pores
    var skinSmooth: Float? = nil
    /// .cube LUT (file name in the layer image folder). Empty = off. Applied to sRGB display values.
    var lut: String = ""
    /// Layer effects (stacked in order like smart filters, Effects.swift). Optional since older documents lack it
    var effects: [LayerEffect]? = nil
    var fx: [LayerEffect] { effects ?? [] }
    /// Tone curves (RGB, luma, channels). nil = off
    var curves: CurveSet? = nil
    /// Per-color hue/saturation/lightness for the eight basic colors (ColorRange.basic): dHue, dSat, dLight × 8. nil = off
    var hsl: [Float]? = nil
    /// Color-LUT pass for the luma curve and per-color adjustments (nil when neither is set)
    var colorKey: ColorLUT.Key? {
        var k = ColorLUT.Key()
        if let c = curves { k.luma = c.luma }
        if let h = hsl, h.count == ColorRange.basic.count * 3 {
            for i in k.editor.indices where i < ColorRange.basic.count {
                k.editor[i].dHue = h[i * 3]; k.editor[i].dSat = h[i * 3 + 1]; k.editor[i].dLight = h[i * 3 + 2]
            }
        }
        return k.isNeutral ? nil : k
    }
}

/// One brush stroke of a brush mask (decoded source coordinates).
struct MaskStroke: Equatable, Hashable, Codable {
    var points: [Double]           // x0, y0, x1, y1, …
    var radius: Double
    var hardness: Double = 0.5     // 0 soft – 1 hard
    var flow: Double = 1
    var erase = false
    /// Imported brush tip (image in the preset folder). If set, stamps the tip instead of a line.
    var tip: String? = nil
    /// Brush tip spacing (fraction of diameter)
    var spacing: Double? = nil
}

/// Layer mask. All coordinates are decoded source coordinates, so it moves with the photo through geometry corrections.
struct LayerMask: Equatable, Codable {
    enum Kind: String, Codable { case full, brush, linear, radial, rect, ellipse, polygon, image }
    var kind: Kind = .full
    var strokes: [MaskStroke] = []
    /// Linear: start point (100% effect) → end point (0%).
    var linear: [Double] = [0, 0, 0, 0]
    /// Radial: center x, y, radius x, radius y. Inside is 100%.
    var radial: [Double] = [0, 0, 0, 0]
    /// Radial edge feather 0–1.
    var radialFeather: Double = 0.5
    /// Rectangle/ellipse selection: two corners x0, y0, x1, y1 (source coordinates)
    var box: [Double] = [0, 0, 0, 0]
    /// Lasso selection: x0, y0, x1, y1, … (source coordinates, closed polygon)
    var polygon: [Double] = []
    /// AI selection mask image (grayscale PNG in the layer image folder, covering the whole source)
    var maskFile: String = ""
    var invert = false
    /// Extra blur over the whole mask (source pixels).
    var feather: Double = 0
    /// Luma range: effect only within this brightness range (display values 0–1).
    var lumaMin: Float = 0
    var lumaMax: Float = 1
    var lumaSoft: Float = 0.1
    var hasLumaRange: Bool { lumaMin > 0 || lumaMax < 1 }

    // Selection (all optional since older documents lack them)
    /// Selection add/subtract/intersect: combined into this mask shape in order
    var combos: [MaskCombo]? = nil
    /// Expand (+) / contract (−), source pixels
    var grow: Double? = nil
    /// Border: only this width around the edge (source pixels)
    var border: Double? = nil
    /// Select and Mask: smooth (source pixels), contrast (0–100), shift edge (−100–100 %)
    var smooth: Double? = nil
    var contrast: Double? = nil
    var shiftEdge: Double? = nil
    /// Refine edge (hair, branches): radius for refining the mask guided by photo luminance (source pixels)
    var refine: Double? = nil
    /// Color range: display RGB + fuzziness (0–1). Only areas close to this color
    var colorRange: [Float]? = nil
    /// Brush mask starts white (fully visible) (hide with the eraser)
    var brushWhite: Bool? = nil
    /// Vector mask (pen path, source coordinates)
    var vector: VectorPath? = nil
}

/// One mask combine step (combined shapes don't have their own combines)
struct MaskCombo: Equatable, Codable {
    enum Op: String, Codable { case add, subtract, intersect }
    var op: Op
    var mask: LayerMask
}

/// Image layer picture: a file in the layer image folder and its position in decoded source coordinates.
/// Goes through the same geometry corrections as the photo (rotation, keystone, crop) and moves with it.
struct LayerImage: Equatable, Codable {
    var file: String
    /// Center (source pixels), width (source pixels), rotation (°, counterclockwise +)
    var cx: Double
    var cy: Double
    var width: Double
    var rotation: Double = 0
    /// Free transform (perspective, distort, skew): four corners in source coordinates (bottom-left, bottom-right, top-right, top-left). Replaces position/size/rotation when set
    var quad: [Double]? = nil
    /// Warp grid: 4×4 Bézier control points (source coordinates, from the bottom row)
    var mesh: [Double]? = nil
    /// Puppet pins: (original x, y, moved x, y) repeated
    var pins: [Double]? = nil
    /// Height (source pixels). Absent means image aspect (set when free transform changes the aspect)
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
    /// Lock: blocks mask painting and value changes.
    var locked = false
    /// Clipping mask: effect only inside the mask of the layer right below (⌥⌘G).
    var clipped = false
    /// "adjust" adjustment layer, "image" image (pixel) layer, "group" group.
    var kind = "adjust"
    /// Fill opacity: applies to layer content only. With hard mix, unlike opacity, it softens the result.
    var fill: Float = 1
    /// Id of the containing group. A group's children are gathered right before (below) the group item in the array.
    var group: String?
    /// Image layer picture and position.
    var image: LayerImage?

    /// Layer created by a layer-edit brush tool (dodge, burn, etc.). Picking the same tool again continues painting on it.
    var preset: String?

    var isGroup: Bool { kind == "group" }
    var isImage: Bool { kind == "image" }
    var isFill: Bool { kind == "fill" }
    /// Background copy: a layer duplicating the background (RAW develop). Has its own retouch spots
    var isCopy: Bool { kind == "copy" }
    /// Retouch spots of a background copy layer (source coordinates)
    var spots: [RetouchSpot] = []
    /// Fill layer color: three RGB values (solid) or six (gradient: start + end color), display values 0–1
    var fillColor: [Float] = []
    /// Gradient fill start/end (source coordinates x0, y0, x1, y1)
    var fillPoints: [Double] = []
    /// Layer styles (shadow, stroke, glow, etc., LayerStyles.swift). Only for layers with shape (image, fill, text, shape)
    var styles: LayerStyles? = nil
    /// Blend If: this layer's brightness [black start, black end, white start, white end] + the same four for the layer below (display 0–1)
    var blendIf: [Float]? = nil
    /// Fill pattern: nil solid/gradient, 0 checker, 1 stripes, 2 clouds, 3 dots (colors 1·2 are fillColor's six values)
    var fillPattern: Int? = nil
    var fillScale: Float? = nil
    /// Imported pattern image (layer image folder). If set, tiled
    var fillPatternFile: String? = nil
    /// Multi-color gradient fill (position, midpoint, r, g, b repeated)
    var fillStops: [Float]? = nil
    /// Link: layers with the same value move together
    var link: String? = nil
    /// Text layer content (kind "text"). Text imported from PSD uses the embedded image until edited.
    var text: LayerText? = nil
    /// Liquify strokes (source coordinates)
    var liquify: [LiquifyStroke]? = nil
    /// Paint layer strokes (kind "paint")
    var paint: [PaintStroke]? = nil
    /// Original data of an adjustment layer imported from PSD ("key:base64") — written back as is on PSD export if unedited
    var psdBlock: String? = nil
    /// Shape layer (kind "shape"): path, fill, stroke
    var vector: VectorShape? = nil
    var isText: Bool { kind == "text" }
    /// Layers that can take styles
    var takesStyles: Bool { isImage || isFill || kind == "text" || kind == "shape" || kind == "paint" }

    /// PSD blend modes and names → Core Image filters.
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
    /// Groups only: children composite directly onto the layers below
    static let passThrough = ("passThrough", "통과")
}

/// Adjustment layer compositing. Applies this layer's adjustments to the composite below, blends with the blend mode,
/// then mixes by mask × opacity.
enum Layers {
    /// `shape`: geometry-corrects and crops the source-coordinate mask to fit the view frame (same transform as the photo).
    static func apply(_ layers: [AdjustLayer], to image: CIImage, guide: CIImage, scale: CGFloat,
                      guideScale gs: CGFloat, native: CGSize, shape: (CIImage, CGFloat) -> CIImage,
                      toDisplay: ((CGPoint) -> CGPoint)? = nil, gamma: Bool = false) -> CIImage {
        // Gamma blending: mixing and blend modes run on display gamma values (PSD documents). The image graph is built right here,
        // so it's flagged on this thread only.
        let td = Thread.current.threadDictionary
        let saved = td[gammaKey]
        td[gammaKey] = gamma
        defer { td[gammaKey] = saved }
        var out = image, g = guide
        var below: CIImage?        // mask of the layer right below (for clipping)
        var belowG: CIImage?
        let byID = Dictionary(layers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func visible(_ l: AdjustLayer, depth: Int = 0) -> Bool {
            guard l.enabled, l.opacity > 0, depth < 32 else { return false }
            guard let p = l.group.flatMap({ byID[$0] }) else { return true }
            return visible(p, depth: depth + 1)
        }
        // Result at group start (group opacity/mask blend against this)
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
                guard let (s0, g0) = groupStart[layer.id] else { continue }   // empty group
                let mode = layer.blend == passThroughKey ? "normal" : layer.blend
                // Pass-through: blend the children's composite with the group start by mask and opacity.
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
                // Duplicate the background and apply this layer's retouch spots (spots mapped from source to view coordinates)
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
                below = multiply(mask, LayerStyles.alphaGray(top))   // Upper layers are clipped to the content shape
                if let st = layer.styles, st.isActive {
                    // Styles follow the mask shape: clip content to the mask, and don't reapply the mask afterwards
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

    /// Source-coordinate retouch spots → view (post-geometry) coordinates. Radius scale is measured from the distance of two points.
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

    // MARK: - Fill layers

    /// Solid or linear gradient fill (fill layer). Gradients are in source coordinates, so they follow geometry corrections.
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
            // Scale by the pattern size (%) and tile in source coordinates
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
            // Patterns are laid in source coordinates too and follow geometry corrections
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

    /// Multi-color gradient → 1024×1 image (working-space linear values)
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

    // MARK: - Image layers

    private static var imageCache: [String: CIImage] = [:]
    /// Most-recently-used order (on overflow, evict just the oldest. It used to clear everything past 8, so documents with many layer/mask images
    /// re-read images on every draw, and the renderer created buffers for each new image, growing memory to tens of GB)
    private static var imageOrder: [String] = []
    private static let imageLock = NSLock()

    static func sourceImage(_ file: String) -> CIImage? {
        imageLock.lock(); defer { imageLock.unlock() }
        // Linked image ("link:path"): reads the source file directly and rereads it when the file changes (smart object link)
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
        // Images read from files decode at draw time, so holding several is cheap
        while imageOrder.count >= 64 { imageCache[imageOrder.removeFirst()] = nil }
        imageCache[key] = img
        imageOrder.append(key)
        return img
    }

    /// Places an image layer in source coordinates and fits it to the view frame through the photo's geometry corrections. Transparent outside.
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
        // Smooth downscale first so it doesn't alias when shrinking.
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

    /// Clips content to the mask shape (transparent outside the mask)
    static func cut(_ top: CIImage, _ mask: CIImage) -> CIImage {
        top.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), "inputMaskImage": mask])
            .cropped(to: top.extent)
    }

    static let gammaKey = "duochrome.gammaBlend"
    private static var gammaBlend: Bool { (Thread.current.threadDictionary[gammaKey] as? Bool) ?? false }
    /// Working space (linear Rec.2020) ↔ sRGB gamma values
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

    /// Blend If weights (brightness ranges of this layer's result and the result below)
    static func blendIfMask(_ v: [Float], this: CIImage, below: CIImage) -> CIImage {
        guard let k = blendIfK else { return CIImage(color: .white).cropped(to: below.extent) }
        let c = v.map { CGFloat($0) }
        return k.apply(extent: below.extent, arguments: [this, below, CIVector(x: c[0], y: c[1], z: c[2], w: c[3]),
                                                           CIVector(x: c[4], y: c[5], z: c[6], w: c[7])]) ?? below
    }

    private static func multiply(_ a: CIImage, _ b: CIImage) -> CIImage {
        a.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: b]).cropped(to: a.extent)
    }

    /// Dissolve: randomly picks opacity-worth of pixels and shows them at 100%.
    private static func dissolve(_ mask: CIImage, opacity: Float) -> CIImage {
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: mask.extent)
        return GPU.run("dissolve_mask", [mask, noise], params: [opacity], extent: mask.extent)
    }

    /// `fill`: fill opacity. Multiplied into the upper layer content's alpha before blending (hard mix is handled in its kernel).
    private static func blend(_ top: CIImage, over base: CIImage, mode: String, fill: Float) -> CIImage {
        if gammaBlend { return decode(blendLinear(encode(top), over: encode(base), mode: mode, fill: fill)).cropped(to: base.extent) }
        return blendLinear(top, over: base, mode: mode, fill: fill)
    }

    private static func blendLinear(_ top: CIImage, over base: CIImage, mode: String, fill: Float) -> CIImage {
        if mode == "hardMix" { return GPU.run("hard_mix", [top, base], params: [fill], extent: base.extent) }
        var t = top
        if fill < 1 {
            let f = CGFloat(max(fill, 0))
            // CIColorMatrix acts on unpremultiplied color, so reduce alpha only (reducing color too would halve it twice).
            t = t.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: f)])
        }
        guard let filter = AdjustLayer.blendModes.first(where: { $0.0 == mode })?.2 else {
            return t.composited(over: base).cropped(to: base.extent)
        }
        return t.applyingFilter(filter, parameters: [kCIInputBackgroundImageKey: base]).cropped(to: base.extent)
    }

    /// Applies layer adjustments. Local tools (clarity, dehaze) use the same guide approach as the base develop.
    static func develop(_ a: LocalAdjust, _ image: CIImage, guide: CIImage, scale: CGFloat,
                        guideScale gs: CGFloat) -> (CIImage, CIImage) {
        var out = image, g = guide
        // Filters (blur, sharpen, high pass, etc.) apply first. Radius = source pixels × preview scale.
        if a.hasFilter {
            out = filters(a, out, scale: scale)
            g = gs == scale ? out : filters(a, g, scale: gs)
        }
        func pixel(_ img: CIImage, _ sc: CGFloat) -> CIImage {
            var o = img
            if a.exposure != 0 { o = o.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure]) }
            if a.temperature != 0 || a.tint != 0 {
                // Shift relative to 6500K. Positive is warmer.
                o = o.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0),
                    "inputTargetNeutral": CIVector(x: CGFloat(6500 - a.temperature * 25), y: CGFloat(-a.tint * 0.8)),
                ])
            }
            var s = DevelopSettings()
            s.contrast = a.contrast; s.brightness = a.brightness; s.saturation = a.saturation
            s.highlightTone = a.highlightTone; s.shadow = a.shadow
            if let c = a.curves { s.curves = c }
            o = Develop.tone(s, o, scale: sc).cropped(to: img.extent)
            if let k = a.colorKey { o = ColorLUT.apply(k, to: o).cropped(to: img.extent) }
            return colorAdjust(a, o)
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
            // Blend with a large blur (evens blotches) and restore the difference from a small blur (fine texture)
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

    /// Color adjustments (vibrance, hue, photo filter, channel mixer, gradient map, posterize, threshold, invert).
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
            // Multiply by the filter color normalized to brightness 1 (brightness nearly unchanged, only warmer/cooler)
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
            // brightness (display gamma) → gradient
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
        // Posterize, threshold, and invert in display gamma (in linear the steps crowd into the shadows)
        if a.posterize >= 2 || a.threshold > 0 || a.invert >= 0.5 {
            var gm = o.applyingFilter("CIColorClamp").applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1 / 2.2])
            if a.posterize >= 2 { gm = gm.applyingFilter("CIColorPosterize", parameters: ["inputLevels": a.posterize]) }
            if a.threshold > 0 { gm = gm.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": a.threshold / 255]) }
            if a.invert >= 0.5 { gm = gm.applyingFilter("CIColorInvert") }
            o = gm.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 2.2])
        }
        return o.cropped(to: e)
    }

    // MARK: - Masks

    /// Mask image (grayscale, view frame coordinates). `base` is the result up to the layer below, used for luma range.
    static func maskImage(_ m: LayerMask, scale: CGFloat, native: CGSize, shape: (CIImage, CGFloat) -> CIImage,
                          base: CIImage) -> CIImage {
        let nativeRect = CGRect(x: 0, y: 0, width: native.width * scale, height: native.height * scale).integral
        var mask = shapeMask(m, scale: scale, native: native)
        // Vector mask: inside the path only (multiplied with the raster mask)
        if let v = m.vector, !v.isEmpty {
            mask = mask.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: VectorRender.mask(v, scale: scale, nativeRect: nativeRect)]).cropped(to: nativeRect)
        }
        // Selection add/subtract/intersect (in source coordinates)
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
        // expand · contract · border · smooth · contrast · shift edge
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
            // Move the midpoint (0.5) and steepen the slope
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

    /// Color range: distance to the picked color in display values → 1 when close (soft within the fuzziness)
    static let colorRangeK = CIColorKernel(source: """
        kernel vec4 k(__sample s, vec3 c, float fuzz) {
            vec3 d = pow(clamp(s.rgb, 0.0, 1.0), vec3(1.0 / 2.2)) - c;
            float w = 1.0 - smoothstep(fuzz * 0.5, fuzz, length(d));
            return vec4(w, w, w, 1.0);
        }
        """)

    /// Refine edge: guided filter steered by photo luminance (the mask clings to hair and twigs)
    static func refineMask(_ mask: CIImage, guide: CIImage, radius r: CGFloat) -> CIImage {
        let e = mask.extent
        let I = guide.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0]).applyingFilter("CIColorClamp").cropped(to: e)
        let p = mask.cropped(to: e)
        func box(_ x: CIImage) -> CIImage { x.clampedToExtent().applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: r]).cropped(to: e) }
        func mul(_ a: CIImage, _ b: CIImage) -> CIImage { a.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: b]).cropped(to: e) }
        guard let k = guidedK else { return mask }
        let mI = box(I), mp = box(p), mIp = box(mul(I, p)), mII = box(mul(I, I))
        let ab = k.apply(extent: e, arguments: [mI, mp, mIp, mII, 0.0004]) ?? mask
        // ab: r = a, g = b → averaged again, q = a·I + b
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

    /// One mask shape (source coordinates and scale, before combining/refining)
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
            // Draw a circle, then stretch vertically into an ellipse.
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

    /// Lasso selection mask (filled polygon). Drawn at up to 1/2 resolution and upscaled.
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

    /// Brush stroke mask. A soft mask doesn't need full resolution, so it's drawn at up to 1/2 and upscaled.
    /// Hardness comes from the blur radius.
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
                    // Stamp the imported brush tip (the eraser has no black tip, so it uses lines)
                    if !stroke.erase {
                        PresetFiles.stamp(ctx, tip: tip, points: pts, diameter: stroke.radius * 2 * rs,
                                          spacing: stroke.spacing ?? 0.25, alpha: stroke.flow)
                        continue
                    }
                }
                // The eraser covers with black. Painting accumulates by flow.
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
            // Softer brushes blur more (by mean radius).
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

/// Image layer picture folder. Test runs use a temp folder.
enum LayerImageStore {
    /// Current catalog (set on open). Layer images, AI masks, and LUTs live in the catalog's Assets folder.
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

    /// Old layer image folder (read only when migrating)
    static var legacyFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Duochrome/LayerImages", isDirectory: true)
    }

    static func url(_ file: String) -> URL { folder.appendingPathComponent(file) }

    /// Copies a file in and returns its name (the layer survives moving or deleting the source).
    static func importFile(_ src: URL) throws -> String {
        let name = UUID().uuidString + "." + (src.pathExtension.isEmpty ? "png" : src.pathExtension.lowercased())
        try FileManager.default.copyItem(at: src, to: url(name))
        return name
    }

    /// Writes data (a pasted image) to a file.
    static func importData(_ data: Data, ext: String) throws -> String {
        let name = UUID().uuidString + "." + ext
        try data.write(to: url(name))
        return name
    }
}

/// Reads a .cube LUT (3D only). Red changes fastest, same as CIColorCube.
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
                // Output values to 0–1 (adjust if the domain differs)
                for c in 0..<3 { values.append((v[c] - lo[c]) / max(hi[c] - lo[c], 1e-6)) }
                values.append(1)
            }
        }
        guard n >= 2, values.count == n * n * n * 4 else { return nil }
        return (n, values.withUnsafeBufferPointer { Data(buffer: $0) })
    }
}
