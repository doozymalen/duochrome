import CoreImage
import QuartzCore
import ImageIO
import UniformTypeIdentifiers

/// Develop values of the RAW layer.
struct DevelopSettings: Equatable, Codable {
    // white balance
    var temperature: Float = 5500
    var tint: Float = 0
    // exposure (contrast, brightness, saturation are -100–100)
    var exposure: Float = 0
    var contrast: Float = 0
    var brightness: Float = 0
    var saturation: Float = 0
    // high dynamic range (all -100–100)
    /// Highlights from old files (0–100, higher recovers more). New value is highlights; display and math use highlightTone.
    var highlight: Float = 0
    /// Highlights -100–100: + brightens bright areas further, - recovers them (docs/SLIDERS.md)
    var highlights: Float = 0
    /// Highlights value used for display and math. The old value (highlight) is read as negative; new edits move it to highlights.
    var highlightTone: Float {
        get { highlights - highlight }
        set { highlights = newValue; highlight = 0 }
    }
    var shadow: Float = 0
    var white: Float = 0
    var black: Float = 0
    // RAW engine stage (0–1, sharpening 0–2). Defaults vary by camera.
    var sharpness: Float = 0
    var detail: Float = 0
    var lumaNoise: Float = 0
    var colorNoise: Float = 0
    var moire: Float = 0
    /// 1 means on. Kept as Float to handle it like sliders.
    var lensCorrection: Float = 1
    /// Base look: 0 Apple default, 1 camera-fitted (only cameras with a look table)
    var look: Float = 1
    /// Overall strength (0–1): how much all adjustments mix with the unadjusted image
    var intensity: Float = 1
    /// Manual lens correction (-100–100, 0–100). Applied at the source coordinate stage.
    /// Distortion + fixes barrel, − fixes pincushion. Chromatic aberration scales the red/blue channels.
    var lensDistortion: Float = 0
    var lensCA: Float = 0
    var lensCABlue: Float = 0
    /// Vignetting (brightens corners) 0–100, edge sharpness 0–100
    var lensVignette: Float = 0
    var lensSharpFalloff: Float = 0
    // Geometry: 90° turns (0–3), flip (1 = on), fine rotation (°), keystone (-100–100), crop
    var quarterTurns: Float = 0
    var flipH: Float = 0
    var flipV: Float = 0
    var rotation: Float = 0
    var keystoneV: Float = 0
    var keystoneH: Float = 0
    var keystoneAspect: Float = 0
    var crop = CropRect()
    /// Locked crop aspect (width/height). 0 is free.
    var cropAspect: Float = 0
    // Base characteristics: camera tone curve strength (0 linear – 1 standard)
    var filmCurve: Float = 1
    /// Contrast added to the base curve (base characteristics "high contrast" / "soft").
    var filmContrast: Float = 0
    /// RAW engine highlight recovery (reconstructs clipped channels).
    var highlightRecoveryOn = true
    // film grain (0–100)
    var grainAmount: Float = 0
    var grainSize: Float = 30
    // clarity, structure (-100–100), dehaze (0–100)
    var clarity: Float = 0
    var structure: Float = 0
    /// Clarity method 0 natural, 1 punch, 2 neutral, 3 classic
    var clarityMethod: Float = 0
    var dehaze: Float = 0
    /// Haze color: hue (°) and amount (0–1). Amount 0 is gray haze.
    var dehazeHue: Float = 30
    var dehazeTint: Float = 0
    // Extra sharpening: amount 0–300, radius in source px, threshold, halo suppression 0–100
    var sharpenAmount: Float = 0
    var sharpenRadius: Float = 0.8
    var sharpenThreshold: Float = 1
    var sharpenHalo: Float = 50
    /// Single-pixel (hot pixel) removal 0–100
    var hotPixels: Float = 0
    /// Grain type 0 fine, 1 silver, 2 soft, 3 color
    var grainType: Float = 0
    // Retouch spots (heal, clone). Decoded source coordinates.
    var spots: [RetouchSpot] = []
    /// Paths in the Paths panel (pen tool, source coordinates)
    var paths: [VectorPath]? = nil
    /// Document mode (DocMode: 0 RGB, 1 grayscale, 2 duotone, 3 CMYK, 4 Lab), color space (ExportRecipe.Space), bit depth (8, 16, 32)
    var docMode: Int? = nil
    var docSpace: String? = nil
    var docDepth: Int? = nil
    /// Two duotone inks (six display RGB values), first ink weight
    var duotone: [Float]? = nil
    var duotoneBalance: Float? = nil
    /// Guides (photo view frame coordinates), count points (x, y repeated)
    var guidesV: [Double]? = nil
    var guidesH: [Double]? = nil
    var countMarks: [Double]? = nil
    /// Background removal: transparent outside this mask (source-coordinate grayscale image). Stays transparent when exported to formats with alpha
    var cutout: String? = nil
    // adjustment layers (bottom to top)
    var layers: [AdjustLayer] = []
    /// Layer comps: named saves of layer visibility, opacity, blend, and position (LayerAdvanced.swift)
    var layerComps: [LayerComp]? = nil
    /// Saved selections (alpha channels, Selection.swift)
    var channels: [SavedSelection]? = nil
    /// Gamma blending (blend in display gamma). On for documents imported from PSD.
    var gammaBlend: Bool? = nil
    /// LCC flat-field map (layer image folder), 1 color cast + 2 light uniformity
    var lcc: String? = nil
    var lccMode: Int? = nil
    /// Perspective crop: four points in frame coordinates (after 90° rotation) (bottom-left, bottom-right, top-right, top-left) → upright rectangle
    var perspective: [Double]? = nil
    /// Canvas size: margins added around the crop (left, bottom, right, top — fractions of the crop size), color (transparent if none)
    var canvasPad: [Double]? = nil
    var canvasColor: [Float]? = nil
    /// Image size (pixel size on export, 0 unchanged) and resampling (0 Lanczos, 1 bicubic, 2 preserve details, 3 nearest)
    var outputSize: [Double]? = nil
    var resample: Int? = nil
    /// Vanishing point planes (four points in source coordinates)
    var vanishingPlane: [Double]? = nil
    /// White balance delta imported from an external catalog (mired, tint). Added to the as-shot values on first open, then cleared
    var importWBShift: [Double]? = nil
    // vignette (-100 darker – 100 lighter)
    var vignette: Float = 0
    // levels (0–1, gamma 1 is unchanged)
    var levelInBlack: Float = 0
    var levelInWhite: Float = 1
    var levelGamma: Float = 1
    var levelOutBlack: Float = 0
    var levelOutWhite: Float = 1
    /// Per-channel levels R/G/B: [input black, input white, gamma, output black, output white]
    var levelsRGB: [[Float]] = Array(repeating: [0, 1, 1, 0, 1], count: 3)
    // curves
    var curves = CurveSet()
    // color balance, B&W (baked into one 3D LUT)
    var color = ColorLUT.Key()

    /// Only the values that require re-decoding the RAW. Other changes reuse the decoded result.
    /// Values that change size and coordinates. When changed, the before image is rebuilt too.
    var geometryKey: [Double] {
        [Double(quarterTurns), Double(flipH), Double(flipV), Double(rotation), Double(keystoneV),
         Double(keystoneH), Double(keystoneAspect), crop.x, crop.y, crop.w, crop.h] + (perspective ?? []) + (canvasPad ?? [])
    }

    var rawStage: [Float] {
        [temperature, tint, exposure, sharpness, detail, lumaNoise, colorNoise, moire, lensCorrection, filmCurve, look]
    }
}

/// Capture info. Shown under the layers panel.
struct ShotInfo {
    var camera = "", lens = ""
    var iso = "", shutter = "", aperture = "", focal = ""
    var date = ""

    init(url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return }
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let aux = p[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        camera = Self.cameraName(make: tiff[kCGImagePropertyTIFFMake] as? String ?? "", model: tiff[kCGImagePropertyTIFFModel] as? String ?? "")
        lens = (exif[kCGImagePropertyExifLensModel] ?? aux[kCGImagePropertyExifAuxLensModel]) as? String ?? ""
        // Canon CR3 records ISOSpeed/RecommendedExposureIndex instead of ISOSpeedRatings.
        let isoValue = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
            ?? exif[kCGImagePropertyExifISOSpeed] as? Int
            ?? exif[kCGImagePropertyExifRecommendedExposureIndex] as? Int
        if let v = isoValue { iso = "ISO \(v)" }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double {
            shutter = t >= 1 ? String(format: "%.1f초", t) : "1/\(Int((1 / t).rounded()))초"
        }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { aperture = String(format: "f/%.1f", f) }
        if let f = exif[kCGImagePropertyExifFocalLength] as? Double { focal = String(format: "%.0fmm", f) }
        date = exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? ""
    }

    /// Make + model. If the model already includes the make (Canon "Canon EOS R5", Nikon "NIKON Z 8"), model only,
    /// with corporate suffixes (CORPORATION, IMAGING CORP., etc.) removed.
    static func cameraName(make: String, model: String) -> String {
        let noise: Set<String> = ["corporation", "corp", "corp.", "co.,ltd.", "co.,ltd", "co.", "ltd", "ltd.", "imaging", "inc", "inc."]
        let maker = make.split(separator: " ").filter { !noise.contains($0.lowercased()) }.joined(separator: " ")
        let m = model.trimmingCharacters(in: .whitespaces)
        if let first = maker.split(separator: " ").first, m.lowercased().hasPrefix(first.lowercased()) { return m }
        return [maker, m].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Source layer at the bottom of the document. Develop values can be changed at any time.
///
/// RAW decoding is left to Core Image RAW (CIRAWFilter). It decodes RAWs from cameras macOS supports directly,
/// and a lower scaleFactor produces previews without decoding the full resolution.
/// Already-rendered files like JPEG and TIFF imitate the same values with Core Image filters.
final class RawDocument {
    enum OpenError: LocalizedError {
        case unsupported(URL)
        var errorDescription: String? {
            switch self {
            case .unsupported(let url): return "\(url.lastPathComponent) 파일을 열 수 없습니다."
            }
        }
    }

    private enum Source {
        /// guide: a 1/8-resolution filter dedicated to building maps for wide-radius tools (clarity, dehaze).
        case raw(CIRAWFilter, guide: CIRAWFilter)
        case rendered(CIImage)
    }

    let url: URL
    let info: ShotInfo
    /// RAW filter for the before view (built on first use)
    private lazy var originalFilter: CIRAWFilter? = CIRAWFilter(imageURL: URL(fileURLWithPath: url.path))

    /// As-shot values only (light, a single RAW filter) — for preview preparation and batch work without building a whole document
    static func shotSettings(url: URL) -> DevelopSettings? {
        guard let raw = CIRAWFilter(imageURL: URL(fileURLWithPath: url.path)) else { return nil }
        return shot(from: raw)
    }

    /// As-shot values of the RAW filter
    static func shot(from raw: CIRAWFilter) -> DevelopSettings {
        var shot = DevelopSettings()
        shot.temperature = raw.neutralTemperature
        shot.tint = raw.neutralTint
        shot.sharpness = raw.sharpnessAmount
        shot.detail = raw.detailAmount
        shot.lumaNoise = raw.luminanceNoiseReductionAmount
        shot.colorNoise = raw.colorNoiseReductionAmount
        shot.moire = raw.moireReductionAmount
        shot.filmCurve = raw.boostAmount
        shot.lensCorrection = raw.isLensCorrectionSupported && raw.isLensCorrectionEnabled ? 1 : 0
        shot.look = Float(AppSettings.defaultLook)
        return shot
    }

    /// Adds the imported white balance delta to the as-shot values (without a document)
    static func importedWB(_ s: DevelopSettings, over asShot: DevelopSettings) -> DevelopSettings {
        guard let sh = s.importWBShift, sh.count == 2 else { return s }
        var o = s
        let mired = 1e6 / Double(asShot.temperature) + sh[0]
        o.temperature = Float(min(max(1e6 / max(mired, 20), 2000), 50000))
        o.tint = Float(min(max(Double(asShot.tint) + sh[1], -150), 150))
        o.importWBShift = nil
        return o
    }
    let isRaw: Bool
    /// Documents opened from PSD/PSB: the background takes the source's place, other layers become adjustment layers on first open (PSDImport)
    private(set) var psd: PSD.File?
    /// Values recorded by the camera. Where "Reset" goes back to.
    let asShot: DevelopSettings
    var settings: DevelopSettings {
        didSet {
            // The crop tool shows the whole frame, so a change of only the crop rect needs no redraw.
            var a = settings, b = oldValue
            if showFullFrame { a.crop = CropRect(); b.crop = CropRect(); a.cropAspect = 0; b.cropAspect = 0 }
            if a != b { cache.removeAll() }
            if settings.geometryKey != oldValue.geometryKey { originalCache.removeAll() }
        }
    }
    /// Keeps settings but discards rendered results (for slider responsiveness).
    func clearCache() { cache.removeAll(); originalCache.removeAll() }

    /// On while the crop tool is in use. Shows the whole uncropped frame.
    var showFullFrame = false {
        didSet { if showFullFrame != oldValue { cache.removeAll(); originalCache.removeAll() } }
    }
    /// On while dragging a slider. Switches demosaicing to the fast method.
    /// Documents used only small, like thumbnails: decode the RAW the fast way (no freezing)
    var quickDecode = false
    var draft = false { didSet { if draft != oldValue { cache.removeAll(); if !draft { draftDecodes.removeAll() } } } }

    private let source: Source
    private var cache: [CGFloat: CIImage] = [:]
    /// Fast path while dragging: freeze the RAW decode into an image at drag start (changing only exposure/temperature won't decode again)
    private var draftDecodes: [String: (key: String, image: CIImage, exposure: Float, temperature: Float, tint: Float)] = [:]

    /// RAW decode inputs excluding exposure, temperature, and tint (if these match, the frozen decode is used)
    private func rawKey(_ s: DevelopSettings) -> String {
        "\(s.sharpness)|\(s.detail)|\(s.lumaNoise)|\(s.colorNoise)|\(s.moire)|\(s.filmCurve)|\(s.lensCorrection)|\(s.highlightRecoveryOn)"
    }
    private var originalCache: [CGFloat: CIImage] = [:]
    /// Preview-only (batch edit, grid, tethering): never decode the RAW larger than preview size (long side AppSettings.previewSize);
    /// larger views upscale the preview. Full size only in layer edit (and always for output work like export and merge)
    var previewOnly = false {
        didSet { if previewOnly != oldValue { draftDecodes.removeAll() } }
    }
    /// Cache key: remembers preview-only and full size separately (so briefly viewing full size, e.g. the focus loupe, doesn't clear the view cache)
    private func cacheKey(_ scale: CGFloat) -> CGFloat { previewOnly && scale > previewScale ? -scale : scale }

    /// Output work (export, merge, print, split channels, focus loupe) temporarily turns preview-only off and uses full size
    func withFullResolution<T>(_ f: () throws -> T) rethrows -> T {
        let was = previewOnly
        if was { previewOnly = false }
        defer { if was { previewOnly = true } }
        return try f()
    }

    /// Preview size scale (by long side)
    var previewScale: CGFloat { min(1, CGFloat(AppSettings.previewSize) / max(nativeSize.width, nativeSize.height, 1)) }

    /// Decoded result size with camera orientation applied.
    let nativeSize: CGSize
    /// Geometry frame (90° rotation applied, before crop).
    var frameSize: CGSize { Geometry.frameSize(settings, native: nativeSize) }
    /// Size used for display and export. The whole frame while the crop tool is active.
    var pixelSize: CGSize { showFullFrame ? frameSize : Geometry.croppedSize(settings, native: nativeSize) }

    init(url: URL) throws {
        self.url = url
        // Strip the variant fragment (#v2) when reading the file
        let url = URL(fileURLWithPath: url.path)
        info = ShotInfo(url: url)
        // Keep a separate filter for the before view. Reusing one filter with changed settings can disturb outputs already built.
        // CIRAWFilter accepts JPEG too. Tell RAW apart by file type.
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        let looksRaw = type?.conforms(to: .rawImage) ?? false
        if PSDImport.extensions.contains(url.pathExtension.lowercased()) {
            let f = try PSD.read(url)
            guard let img = PSDImport.base(f), !img.extent.isEmpty else { throw OpenError.unsupported(url) }
            psd = f
            source = .rendered(img)
            isRaw = false
            nativeSize = img.extent.size
            var shot = DevelopSettings()
            shot.temperature = 6500
            shot.lensCorrection = 0
            asShot = shot
        } else if looksRaw, let raw = CIRAWFilter(imageURL: url),
           let guide = CIRAWFilter(imageURL: url), let full = raw.outputImage, !full.extent.isEmpty {
            // The before-view filter is built on first comparison (about 60 ms per filter, paid on every photo step)
            source = .raw(raw, guide: guide)
            isRaw = true
            nativeSize = full.extent.size
            asShot = Self.shot(from: raw)
        } else if let img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
                  !img.extent.isEmpty {
            source = .rendered(img)
            isRaw = false
            nativeSize = img.extent.size
            // For already-rendered photos, 6500K counts as "unchanged".
            var shot = DevelopSettings()
            shot.temperature = 6500
            shot.lensCorrection = 0
            asShot = shot
        } else {
            throw OpenError.unsupported(url)
        }
        settings = asShot
    }

    /// Converts the imported white balance delta to absolute values (true if changed)
    @discardableResult
    func applyImportedWB() -> Bool {
        guard let sh = settings.importWBShift, sh.count == 2 else { return false }
        var s = settings
        let mired = 1e6 / Double(asShot.temperature) + sh[0]
        s.temperature = Float(min(max(1e6 / max(mired, 20), 2000), 50000))
        s.tint = Float(min(max(Double(asShot.tint) + sh[1], -150), 150))
        s.importWBShift = nil
        settings = s
        return true
    }

    /// Releases file data after all PSD layers are carried over (memory)
    func releasePSD() { psd = nil }

    /// Small image for analysis like histograms and hue distribution: shrinks an already-rendered scale (1/2, 1/4) if available
    /// (rendering 1/8 separately decoded the RAW again, stacking three or four decodes on photo open)
    func analysisImage() -> CIImage {
        if let (sc, img) = cache.filter({ $0.key <= 0.5 && $0.key >= 1.0 / 8 }).min(by: { $0.key < $1.key }) {
            let k = min(1, (1.0 / 8) / sc)
            return k >= 0.999 ? img : img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1])
        }
        return image(scale: 1.0 / 8)
    }

    /// `scale` is one of 1, 1/2, 1/4, 1/8. Result size is pixelSize × scale.
    func image(scale: CGFloat) -> CIImage {
        var settings = SliderResponse.effective(self.settings)
        if layersOff { settings.layers = [] }
        if !layersOff, let hit = cache[cacheKey(scale)] { return hit }
        // Maps for wide-radius tools are built at 1/8 resolution. At source resolution the whole 45 MP,
        // even off screen, had to be decoded and the first 100% view took 3–5 s.
        let guideScale = Develop.guideScale
        // When composites differing only in layers follow (like PSD): skip decoding if a frozen base develop exists
        var frozenKey = ""
        if freezeDecodes {
            var bare = settings; bare.layers = []
            frozenKey = "\(scale)|\(showFullFrame)|" + ((try? JSONEncoder().encode(bare)).map { String(decoding: $0, as: UTF8.self) } ?? "")
            if let f = frozenBase, f.key == frozenKey {
                return finishImage(settings, base: f.base, g: f.guide, layerGuideScale: f.guideScale, scale: scale)
            }
        }
        let mainShaped = shaped(decoded(scale: scale, guide: false), scale)
        let guide: CIImage?
        if scale > guideScale && scale <= 0.5 {
            // Small zooms like fit view: shrink the already-decoded image as the guide (decoding the RAW again added 0.5 s on photo open)
            let g0 = mainShaped.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: guideScale / scale, kCIInputAspectRatioKey: 1])
            let target = CGRect(x: 0, y: 0, width: (mainShaped.extent.width * guideScale / scale).rounded(),
                                height: (mainShaped.extent.height * guideScale / scale).rounded())
            guide = g0.clampedToExtent().cropped(to: target)
        } else {
            guide = scale > guideScale ? shaped(decoded(scale: guideScale, guide: true), guideScale) : nil
        }
        // Airlight is measured only when dehaze is used, in the background. Thumbnails measure on the already-decoded small image (decoding the RAW again at 1/8 cost 0.7 s per photo)
        let haze: Float = settings.dehaze <= 0 ? 0
            : (approximateFromPreview ? (hazeLight ?? Develop.estimateHazeLight(mainShaped)) : hazeLightOrStart())
        var (base, g) = Develop.base(settings, to: mainShaped, guide: guide, scale: scale, haze: haze)
        // Rendering results many times (PSD): composites differ only in layers, so freeze the base develop once and reuse it
        if freezeDecodes, let fb = freeze(base) {
            let fg = freeze(g) ?? g
            frozenBase = (frozenKey, fb, fg, guide == nil ? scale : guideScale)
            base = fb; g = fg
            // With the base develop frozen, the decoded image is no longer needed (45 MP half-float is 360 MB)
            frozenDecodes.removeAll()
        }
        return finishImage(settings, base: base, g: g, layerGuideScale: guide == nil ? scale : guideScale, scale: scale)
    }

    /// After the base develop: layers, finishing, color mode, background removal
    private func finishImage(_ settings: DevelopSettings, base: CIImage, g: CIImage, layerGuideScale: CGFloat, scale: CGFloat) -> CIImage {
        var img = base
        if !settings.layers.isEmpty {
            img = Layers.apply(settings.layers, to: base, guide: g, scale: scale,
                               guideScale: layerGuideScale, native: nativeSize,
                               shape: { [settings, showFullFrame] m, sc in
                                   let t = Geometry.transform(settings, m, scale: sc)
                                   return showFullFrame ? t : Geometry.crop(settings, t)
                               },
                               toDisplay: { [settings, nativeSize, showFullFrame] p in
                                   Geometry.toDisplay(p, settings, native: nativeSize, fullFrame: showFullFrame)
                               }, gamma: settings.gammaBlend ?? false)
        }
        img = Develop.finish(settings, img, scale: scale)
        if settings.intensity < 0.999 {
            let before = originalImage(scale: scale)
            img = before.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: img, kCIInputTimeKey: max(settings.intensity, 0),
            ]).cropped(to: img.extent)
        }
        if settings.docMode != nil || settings.docSpace != nil || settings.docDepth == 8 { img = ColorModes.apply(settings, img) }
        if let cut = settings.cutout {
            // Background removal: transparent outside the mask
            var lm = LayerMask(); lm.kind = .image; lm.maskFile = cut
            let s = settings, full = showFullFrame
            let m = Layers.maskImage(lm, scale: scale, native: nativeSize, shape: { mm, sc in
                let t = Geometry.transform(s, mm, scale: sc)
                return full ? t : Geometry.crop(s, t)
            }, base: img)
            img = img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: m]).cropped(to: img.extent)
        }
        if ProcessInfo.processInfo.environment["DUOCHROME_EXTENT_DEBUG"] != nil {
            NSLog("extent scale %.3f: decoded %@ shaped %@ base %@ final %@ (pixelSize×scale %@)", scale,
                  "\(decoded(scale: scale, guide: false).extent)", "\(shaped(decoded(scale: scale, guide: false), scale).extent)",
                  "\(base.extent)", "\(img.extent)", "\(CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale))")
        }
        if !layersOff { cache[cacheKey(scale)] = img }
        return img
    }

    /// While on, image(scale:) develops without layers and leaves the cache alone (imageWithoutLayers)
    private var layersOff = false
    private var bareCache: [CGFloat: (key: DevelopSettings, full: Bool, draft: Bool, image: CIImage)] = [:]

    /// The develop result without layers: the layer editor's "before"
    func imageWithoutLayers(scale: CGFloat) -> CIImage {
        var bare = settings
        bare.layers = []
        let k = cacheKey(scale)
        if let hit = bareCache[k], hit.key == bare, hit.full == showFullFrame, hit.draft == draft { return hit.image }
        guard !settings.layers.isEmpty else { return image(scale: scale) }
        layersOff = true
        defer { layersOff = false }
        let img = image(scale: scale)
        bareCache[k] = (bare, showFullFrame, draft, img)
        return img
    }

    /// Up to the RAW decoding stage (exposure, white balance, noise, sharpening, lens correction).
    /// For rendering results many times (compositing per PSD layer): decode the RAW once, freeze it, and reuse.
    /// The export renderer doesn't cache intermediates, so each composite decoded 45 MP anew (over a minute for six PSD layers)
    var freezeDecodes = false { didSet { if !freezeDecodes { frozenDecodes.removeAll(); frozenBase = nil } } }
    private var frozenBase: (key: String, base: CIImage, guide: CIImage, guideScale: CGFloat)?
    private var frozenDecodes: [String: (key: String, image: CIImage)] = [:]

    /// For thumbnails: if there's no preview for these exact settings, use another preview of the same photo (as-shot etc.) with only exposure/temperature deltas applied.
    /// Skips the RAW decode (a 45 MP CR3 takes 2 s per photo even downscaled, one at a time). At 320 px the difference is invisible
    var approximateFromPreview = false

    /// Whether to use the preview cache (off for export and fitting tools)
    var usePreviewCache = ProcessInfo.processInfo.environment["DUOCHROME_NO_PREVIEWS"] == nil

    /// Source-coordinate image before geometry (for AI selection masks)
    func nativePreview(scale: CGFloat) -> CIImage { decoded(scale: scale, guide: true) }

    /// Renders an image once and freezes it as a half-float bitmap image (redrawing won't decode the RAW)
    private func freeze(_ img: CIImage) -> CIImage? {
        let e = img.extent.integral
        guard e.width > 0, e.height > 0 else { return nil }
        var data = Data(count: Int(e.width) * Int(e.height) * 8)
        data.withUnsafeMutableBytes { p in
            guard let base = p.baseAddress else { return }
            // For output work (PSD), use the export context that doesn't cache intermediates (the display one held GBs of 45 MP intermediates)
            let ctx = freezeDecodes ? Render.exportContext : Render.context
            ctx.render(img, toBitmap: base, rowBytes: Int(e.width) * 8, bounds: e, format: .RGBAh, colorSpace: Render.workingSpace)
        }
        return CIImage(bitmapData: data, bytesPerRow: Int(e.width) * 8, size: e.size, format: .RGBAh, colorSpace: Render.workingSpace)
            .transformed(by: .init(translationX: e.minX, y: e.minY))
    }

    private func decoded(scale: CGFloat, guide: Bool) -> CIImage {
        let settings = SliderResponse.effective(self.settings)
        switch source {
        case .raw(let main, let guideFilter):
            // Preview cache: zooms within the cache resolution don't decode the RAW (fast stepping)
            if usePreviewCache, let p = PreviewCache.shared.image(url: url, settings: settings),
               previewOnly || nativeSize.width * scale <= p.extent.width * 1.001 {
                let target = CGRect(x: 0, y: 0, width: (nativeSize.width * scale).rounded(), height: (nativeSize.height * scale).rounded())
                let sx = target.width / p.extent.width, sy = target.height / p.extent.height
                let img = sx < 0.75
                    ? p.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy])
                    : p.transformed(by: .init(scaleX: sx, y: sy))
                let e = img.extent
                let fitted = img.transformed(by: .init(translationX: -e.minX, y: -e.minY)).clampedToExtent().cropped(to: target)
                return Lens.apply(settings, Look.apply(fitted, look: settings.look, camera: info.camera))
            }
            if approximateFromPreview, usePreviewCache, !guide {
                var same = settings
                same.exposure = asShot.exposure; same.temperature = asShot.temperature; same.tint = asShot.tint
                for c in [same, asShot] {
                    guard let p = PreviewCache.shared.image(url: url, settings: c) ?? PreviewCache.shared.thumbBase(url: url, settings: c) else { continue }
                    let target = CGRect(x: 0, y: 0, width: max(1, (nativeSize.width * scale).rounded()), height: max(1, (nativeSize.height * scale).rounded()))
                    let sx = target.width / p.extent.width, sy = target.height / p.extent.height
                    var img = p.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy])
                    let e = img.extent
                    img = img.transformed(by: .init(translationX: -e.minX, y: -e.minY)).clampedToExtent().cropped(to: target)
                    let dEV = settings.exposure - c.exposure
                    if abs(dEV) > 1e-4 { img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: dEV]) }
                    if settings.temperature != c.temperature || settings.tint != c.tint {
                        img = img.applyingFilter("CITemperatureAndTint", parameters: [
                            "inputNeutral": CIVector(x: CGFloat(settings.temperature), y: CGFloat(settings.tint)),
                            "inputTargetNeutral": CIVector(x: CGFloat(c.temperature), y: CGFloat(c.tint)),
                        ]).cropped(to: target)
                    }
                    return Lens.apply(settings, Look.apply(img, look: settings.look, camera: info.camera))
                }
            }
            let fullKey = rawKey(settings) + "|\(settings.exposure)|\(settings.temperature)|\(settings.tint)"
            let frozenSlot = "\(guide ? "g" : "m")\(scale)|\(previewOnly)"
            if freezeDecodes, let f = frozenDecodes[frozenSlot], f.key == fullKey {
                return Lens.apply(settings, Look.apply(f.image, look: settings.look, camera: info.camera))
            }
            let raw = guide ? guideFilter : main
            // While dragging, apply only exposure/temperature deltas on the frozen decode (releasing returns to an exact decode)
            let slot = "\(guide ? "g" : "m")\(scale)"
            if draft, let d = draftDecodes[slot], d.key == rawKey(settings) {
                var img = d.image
                let dEV = settings.exposure - d.exposure
                if abs(dEV) > 1e-4 { img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: dEV]) }
                if settings.temperature != d.temperature || settings.tint != d.tint {
                    img = img.applyingFilter("CITemperatureAndTint", parameters: [
                        "inputNeutral": CIVector(x: CGFloat(settings.temperature), y: CGFloat(settings.tint)),
                        "inputTargetNeutral": CIVector(x: CGFloat(d.temperature), y: CGFloat(d.tint)),
                    ])
                }
                return Lens.apply(settings, Look.apply(img.cropped(to: d.image.extent), look: settings.look, camera: info.camera))
            }
            // Preview-only never decodes larger than preview size (the 1/8 guide is unchanged)
            let decodeScale = previewOnly && !guide ? min(scale, previewScale) : scale
            raw.scaleFactor = Float(decodeScale)
            raw.isDraftModeEnabled = guide || draft || quickDecode
            // Thumbnails: decode with as-shot exposure/temperature and keep it as the base; deltas are applied afterwards (next thumbnail without decoding)
            let thumbBaseMode = approximateFromPreview && !guide && usePreviewCache
            var ds = settings
            if thumbBaseMode { ds.exposure = asShot.exposure; ds.temperature = asShot.temperature; ds.tint = asShot.tint }
            raw.exposure = ds.exposure
            raw.neutralTemperature = ds.temperature
            raw.neutralTint = ds.tint
            raw.sharpnessAmount = settings.sharpness
            raw.detailAmount = settings.detail
            raw.luminanceNoiseReductionAmount = settings.lumaNoise
            raw.colorNoiseReductionAmount = settings.colorNoise
            raw.moireReductionAmount = settings.moire
            raw.boostAmount = settings.filmCurve
            if #available(macOS 26, *), raw.isHighlightRecoverySupported {
                raw.isHighlightRecoveryEnabled = settings.highlightRecoveryOn
            }
            if raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = settings.lensCorrection > 0.5 }
            var decodedImage = normalized(raw.outputImage)
            if decodeScale < scale - 1e-6, !decodedImage.extent.isEmpty {
                // Upscale the preview-size decode to the requested zoom
                let k = scale / decodeScale
                let target = CGRect(x: 0, y: 0, width: (nativeSize.width * scale).rounded(), height: (nativeSize.height * scale).rounded())
                decodedImage = decodedImage.transformed(by: .init(scaleX: k, y: k)).clampedToExtent().cropped(to: target)
            }
            if thumbBaseMode, !decodedImage.extent.isEmpty, let frozen = freeze(decodedImage) {
                PreviewCache.shared.storeThumbBase(frozen, url: url, settings: ds)
                var img = frozen
                let dEV = settings.exposure - ds.exposure
                if abs(dEV) > 1e-4 { img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: dEV]) }
                if settings.temperature != ds.temperature || settings.tint != ds.tint {
                    img = img.applyingFilter("CITemperatureAndTint", parameters: [
                        "inputNeutral": CIVector(x: CGFloat(settings.temperature), y: CGFloat(settings.tint)),
                        "inputTargetNeutral": CIVector(x: CGFloat(ds.temperature), y: CGFloat(ds.tint)),
                    ]).cropped(to: frozen.extent)
                }
                return Lens.apply(settings, Look.apply(img, look: settings.look, camera: info.camera))
            }
            if freezeDecodes, !draft, !decodedImage.extent.isEmpty, let frozen = freeze(decodedImage) {
                frozenDecodes[frozenSlot] = (fullKey, frozen)
                decodedImage = frozen
            }
            // Preview-only without a preview: build one (so later views won't decode the RAW; not while dragging)
            if previewOnly, !guide, !draft, usePreviewCache { PreviewCache.shared.ensure(url: url, settings: settings) }
            if draft, decodeScale <= 0.5, !decodedImage.extent.isEmpty {
                // First frame of a drag: freeze the decode as a half-float image so later frames don't decode again
                let e = decodedImage.extent.integral
                var data = Data(count: Int(e.width) * Int(e.height) * 8)
                let ok = data.withUnsafeMutableBytes { p -> Bool in
                    guard let base = p.baseAddress else { return false }
                    Render.context.render(decodedImage, toBitmap: base, rowBytes: Int(e.width) * 8, bounds: e, format: .RGBAh, colorSpace: Render.workingSpace)
                    return true
                }
                if ok {
                    let frozen = CIImage(bitmapData: data, bytesPerRow: Int(e.width) * 8, size: e.size, format: .RGBAh, colorSpace: Render.workingSpace)
                        .transformed(by: .init(translationX: e.minX, y: e.minY))
                    draftDecodes[slot] = (rawKey(settings), frozen, settings.exposure, settings.temperature, settings.tint)
                    decodedImage = frozen
                }
            }
            return Lens.apply(settings, Look.apply(decodedImage, look: settings.look, camera: info.camera))
        case .rendered(let base):
            var out = scaled(base, scale)
            if settings.exposure != 0 {
                out = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: settings.exposure])
            }
            if settings.temperature != asShot.temperature || settings.tint != asShot.tint {
                out = out.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: CGFloat(settings.temperature), y: CGFloat(settings.tint)),
                    "inputTargetNeutral": CIVector(x: CGFloat(asShot.temperature), y: 0),
                ])
            }
            return Lens.apply(settings, out)
        }
    }

    func originalImage(scale: CGFloat) -> CIImage {
        if let hit = originalCache[cacheKey(scale)] { return hit }
        let img: CIImage
        switch source {
        case .raw:
            guard let original = originalFilter else { return image(scale: scale) }
            let os = previewOnly ? min(scale, previewScale) : scale
            original.scaleFactor = Float(os)
            var o = normalized(original.outputImage)
            if os < scale - 1e-6 {
                let target = CGRect(x: 0, y: 0, width: (nativeSize.width * scale).rounded(), height: (nativeSize.height * scale).rounded())
                o = o.transformed(by: .init(scaleX: scale / os, y: scale / os)).clampedToExtent().cropped(to: target)
            }
            img = shaped(Look.apply(o, look: settings.look, camera: info.camera), scale, retouch: false)
        case .rendered(let base):
            img = shaped(scaled(base, scale), scale, retouch: false)
        }
        originalCache[cacheKey(scale)] = img
        return img
    }

    /// Picks the retouch source automatically (compared on the pre-retouch 1/8 image).
    func autoSource(target: CGPoint, radius: Double) -> CGPoint {
        let scale = Develop.guideScale
        return Retouch.pickSource(target: target, radius: radius, in: decoded(scale: scale, guide: true), scale: scale)
    }

    /// For mask display: layer mask in view frame coordinates (luma range approximated from the current result's brightness).
    func maskPreview(_ id: String, scale: CGFloat) -> CIImage? {
        guard let layer = settings.layers.first(where: { $0.id == id }) else { return nil }
        let base = image(scale: scale)
        let s = settings, full = showFullFrame
        return Layers.maskImage(layer.mask, scale: scale, native: nativeSize, shape: { m, sc in
            let t = Geometry.transform(s, m, scale: sc)
            return full ? t : Geometry.crop(s, t)
        }, base: base)
    }

    /// Selection mask for the canvas outline (same geometry as layer masks). `base` is the image it is drawn over.
    func selectionPreview(_ m: LayerMask, scale: CGFloat, base: CIImage) -> CIImage {
        let s = settings, full = showFullFrame
        return Layers.maskImage(m, scale: scale, native: nativeSize, shape: { mm, sc in
            let t = Geometry.transform(s, mm, scale: sc)
            return full ? t : Geometry.crop(s, t)
        }, base: base)
    }

    /// Source position of a stroke (offset from the stroke).
    func autoStrokeOffset(path: [CGPoint], radius: Double) -> CGPoint {
        let scale = Develop.guideScale
        return Retouch.pickStrokeOffset(path, radius: radius, in: decoded(scale: scale, guide: true), scale: scale)
    }

    /// For auto keystone: finds straight lines in the 1/8 image (90° rotation/flip only), in frame coordinates (source pixels).
    func detectFramedLines() -> (vertical: [(CGPoint, CGPoint)], horizontal: [(CGPoint, CGPoint)]) {
        let scale = Develop.guideScale
        let img = decoded(scale: scale, guide: true)
        let (turn, _) = Geometry.turnTransform(settings, w: img.extent.width, h: img.extent.height)
        let found = LineDetector.detect(img.transformed(by: turn))
        func up(_ l: LineDetector.Line) -> (CGPoint, CGPoint) {
            (CGPoint(x: l.a.x / scale, y: l.a.y / scale), CGPoint(x: l.b.x / scale, y: l.b.y / scale))
        }
        return (found.vertical.map(up), found.horizontal.map(up))
    }

    /// View coordinates (displayed image) ↔ decoded source coordinates.
    func toNative(_ p: CGPoint) -> CGPoint { Geometry.fromDisplay(p, settings, native: nativeSize, fullFrame: showFullFrame) }
    func toDisplay(_ p: CGPoint) -> CGPoint { Geometry.toDisplay(p, settings, native: nativeSize, fullFrame: showFullFrame) }

    /// White balance eyedropper: finds the temperature/tint that makes that on-screen point neutral.
    ///
    /// Repeatedly feeds values into the RAW engine and measures the point's linear RGB (Newton's method in mired/tint space).
    /// Measured with the dedicated 1/8-resolution filter, so each step takes tens of ms. Uses a 5×5 mean around the point.
    ///
    /// The RAW engine's `neutralLocation` was tried too, but it moved only temperature and barely tint, so the clicked spot didn't turn neutral
    /// (sky: 11,936K vs 7,732K with this method, resulting RGB 230·230·229). So we fit it directly.
    ///
    /// Uses only a dedicated filter and a copy of values, so it's safe on a background thread (takes close to a second).
    /// With `display` nil, auto white balance: makes the whole-photo mean neutral (gray world assumption).
    func neutralWhiteBalance(at display: CGPoint?) -> (temperature: Float, tint: Float)? {
        guard case .raw = source, let g = CIRAWFilter(imageURL: URL(fileURLWithPath: url.path)) else { return nil }
        let settings = self.settings, fullFrame = self.showFullFrame
        let scale = Develop.guideScale
        let p = display.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
        var measures = 0
        let started = CACurrentMediaTime()
        defer {
            if ProcessInfo.processInfo.environment["DUOCHROME_BENCH"] != nil {
                NSLog("wb: %d measures, %.0f ms", measures, (CACurrentMediaTime() - started) * 1000)
            }
        }
        func measure(_ temp: Float, _ tint: Float) -> SIMD3<Float>? {
            measures += 1
            g.scaleFactor = Float(scale)
            g.isDraftModeEnabled = true
            g.exposure = settings.exposure
            g.neutralTemperature = temp
            g.neutralTint = tint
            g.boostAmount = settings.filmCurve
            if g.isLensCorrectionSupported { g.isLensCorrectionEnabled = settings.lensCorrection > 0.5 }
            let t = Geometry.transform(settings, Look.apply(normalized(g.outputImage), look: settings.look, camera: info.camera), scale: scale)
            let img = fullFrame ? t : Geometry.crop(settings, t)
            guard let p else {
                // Whole-photo mean (clipped at 0.95 so blown areas don't mix in)
                var px = [Float](repeating: 0, count: 4)
                let avg = img.applyingFilter("CIColorClamp", parameters: ["inputMaxComponents": CIVector(x: 0.95, y: 0.95, z: 0.95, w: 1)])
                    .applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: img.extent)])
                Render.context.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                      format: .RGBAf, colorSpace: Render.workingSpace)
                return SIMD3(px[0], px[1], px[2])
            }
            let r = CGRect(x: (p.x - 2).rounded(.down), y: (p.y - 2).rounded(.down), width: 5, height: 5)
            guard img.extent.contains(r) else { return nil }
            var px = [Float](repeating: 0, count: 25 * 4)
            Render.context.render(img, toBitmap: &px, rowBytes: 5 * 16, bounds: r, format: .RGBAf,
                                  colorSpace: Render.workingSpace)
            var sum = SIMD3<Float>(0, 0, 0)
            for i in 0..<25 { sum += SIMD3(px[i * 4], px[i * 4 + 1], px[i * 4 + 2]) }
            return sum / 25
        }
        func error(_ c: SIMD3<Float>) -> SIMD2<Float> { SIMD2(log(c.x / c.y), log(c.z / c.y)) }

        // Measure the slope (Jacobian) by differences only the first time, then update with Broyden's method.
        // Measuring anew each time decoded three times per iteration and took close to a second.
        var x = SIMD2<Float>(1e6 / settings.temperature, settings.tint)
        guard let c0 = measure(1e6 / x.x, x.y), min(c0.x, c0.y, c0.z) > 1e-4,
              let cm = measure(1e6 / (x.x + 5), x.y), let ct = measure(1e6 / x.x, x.y + 3) else { return nil }
        var e = error(c0)
        var j = (error(cm) - e) / 5, k = (error(ct) - e) / 3   // columns: ∂e/∂mired, ∂e/∂tint
        for _ in 0..<8 {
            if abs(e.x) < 0.003 && abs(e.y) < 0.003 { break }
            let det = j.x * k.y - k.x * j.y
            guard abs(det) > 1e-9 else { return nil }
            // [j k] · Δ = −e
            var d = SIMD2<Float>((-e.x * k.y + k.x * e.y) / det, (-j.x * e.y + e.x * j.y) / det)
            let next = SIMD2<Float>(min(max(x.x + d.x, 1e6 / 50000), 1e6 / 2000), min(max(x.y + d.y, -150), 150))
            d = next - x
            guard let c = measure(1e6 / next.x, next.y), min(c.x, c.y, c.z) > 1e-4 else { return nil }
            let e2 = error(c)
            // Broyden: J += ((Δe − JΔ) Δᵀ) / (ΔᵀΔ)
            let dd = d.x * d.x + d.y * d.y
            if dd > 1e-9 {
                let r = (e2 - e) - (j * d.x + k * d.y)
                j += r * (d.x / dd); k += r * (d.y / dd)
            }
            x = next; e = e2
        }
        let mired = x.x, tint = x.y
        return (1e6 / mired, tint)
    }

    /// Geometry and crop. Applied before the develop stage (so vignette and histogram are crop-relative).
    private func shaped(_ img0: CIImage, _ scale: CGFloat, retouch: Bool = true) -> CIImage {
        let img = settings.lcc.map { LCC.apply(img0, file: $0, mode: settings.lccMode ?? 3, scale: scale) } ?? img0
        let r = retouch && !settings.spots.isEmpty ? Retouch.apply(settings.spots, to: img, scale: scale) : img
        let t = Geometry.transform(settings, r, scale: scale)
        return showFullFrame ? t : Geometry.crop(settings, t)
    }

    /// Dehaze airlight. Brightest value of the unadjusted photo's dark channel (measured once on first use).
    /// Airlight (dehaze reference). On first use, measured on a background thread by decoding the RAW at 1/8 separately.
    /// Drawn with a common value (0.95) while measuring; when done, clears the render cache and asks for a redraw (measuring on main stalled photo open)
    private var hazeLight: Float?
    private var hazeStarted = false
    static let needsRedraw = Notification.Name("DuochromeDocumentNeedsRedraw")

    /// Measures airlight right away (when precision matters, like export; background-thread documents)
    private func measureHazeNow() -> Float {
        let h = Develop.estimateHazeLight(originalImage(scale: 1.0 / 8))
        hazeLight = h
        return h
    }

    /// Before export: measure airlight precisely if dehaze is used
    func settleForExport() {
        if settings.dehaze > 0, hazeLight == nil { _ = measureHazeNow(); cache.removeAll() }
    }

    private func hazeLightOrStart() -> Float {
        if let h = hazeLight { return h }
        // Off the main thread (export, thumbnails), measure right away
        if !Thread.isMainThread { return measureHazeNow() }
        if !hazeStarted {
            hazeStarted = true
            let fileURL = URL(fileURLWithPath: url.path), look = settings.look, camera = info.camera, isRaw = isRaw
            let fallback: CIImage? = isRaw ? nil : originalImage(scale: 1.0 / 8)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.6) { [weak self] in
                // Don't measure if this document was already released by fast stepping
                BackgroundGate.waitQuiet()
                guard self != nil else { return }
                var small = fallback
                if isRaw, let raw = CIRAWFilter(imageURL: fileURL) {
                    raw.scaleFactor = 1.0 / 8
                    raw.isDraftModeEnabled = true
                    if let o = raw.outputImage {
                        let e = o.extent
                        small = Look.apply(o.transformed(by: .init(translationX: -e.minX, y: -e.minY)), look: look, camera: camera)
                    }
                }
                let h = small.map { Develop.estimateHazeLight($0) } ?? 0.95
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.hazeLight = h
                    self.cache.removeAll()
                    NotificationCenter.default.post(name: Self.needsRedraw, object: self)
                }
            }
        }
        return 0.95
    }

    private func scaled(_ image: CIImage, _ scale: CGFloat) -> CIImage {
        let n = normalized(image)
        return scale == 1 ? n : n.transformed(by: .init(scaleX: scale, y: scale))
    }

    /// The output origin is sometimes nonzero, so normalize it. The canvas assumes origin (0,0).
    private func normalized(_ image: CIImage?) -> CIImage {
        guard let image else { return .empty() }
        let o = image.extent.origin
        return o == .zero ? image : image.transformed(by: .init(translationX: -o.x, y: -o.y))
    }
}
