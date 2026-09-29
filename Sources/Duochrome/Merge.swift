import AppKit
import CoreImage
import ImageIO
import Vision
import simd

/// Multi-photo merge: HDR, panorama (rectilinear, cylindrical, spherical), focus stacking, image stacks (median, mean).
/// All decode RAWs as linear (tone curve and base look off), align and merge, then write a 16-bit linear DNG
/// (exposure and white balance remain adjustable like a RAW).
enum Merge {
    struct Frame {
        var url: URL
        var image: CIImage          // working-space linear
        var exposure: Double        // exposure factor t·ISO/N² (for relative comparison)
        var focal35: Double?        // 35 mm equivalent focal length
        var camera: String
    }

    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    // MARK: - Loading

    static func exposureFactor(_ url: URL) -> (Double, Double?) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] else { return (1, nil) }
        let t = exif[kCGImagePropertyExifExposureTime] as? Double ?? 1
        let n = exif[kCGImagePropertyExifFNumber] as? Double ?? 1
        let iso = Double((exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first ?? exif[kCGImagePropertyExifISOSpeed] as? Int
                         ?? exif[kCGImagePropertyExifRecommendedExposureIndex] as? Int ?? 100)
        var f35 = (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Double).flatMap { $0 > 0 ? $0 : nil }
        if f35 == nil, let f = exif[kCGImagePropertyExifFocalLength] as? Double { f35 = f }   // assume full frame
        return (t * iso / max(n * n, 0.01), f35)
    }

    /// Linearly decoded image (scale 1 = source resolution)
    static func load(_ url: URL, scale: CGFloat) throws -> Frame {
        let doc = try RawDocument(url: url)
        var s = doc.asShot
        s.filmCurve = 0          // tone curve off → scene-linear
        s.look = 0
        s.highlightRecoveryOn = false
        doc.settings = s
        doc.usePreviewCache = false
        let (e, f35) = exposureFactor(url)
        return Frame(url: url, image: doc.image(scale: scale), exposure: e, focal35: f35, camera: doc.info.camera)
    }

    // MARK: - Alignment (Vision)

    /// Small image for alignment (gamma, brightness matched)
    /// frame: reference region so both images share coordinates (origin moved to 0 and downscaled)
    static func probe(_ img: CIImage, gain: Double, frame: CGRect, long: CGFloat = 1600) -> (CIImage, CGFloat) {
        let k = min(1, long / max(frame.width, frame.height))
        let g = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: log2(max(gain, 1e-6))])
            .applyingFilter("CIColorClamp").applyingFilter("CILinearToSRGBToneCurve")
            .composited(over: CIImage(color: .black).cropped(to: frame)).cropped(to: frame)
        let small = g.transformed(by: .init(translationX: -frame.minX, y: -frame.minY)).transformed(by: .init(scaleX: k, y: k))
        return (small.cropped(to: CGRect(x: 0, y: 0, width: (frame.width * k).rounded(.down), height: (frame.height * k).rounded(.down))), k)
    }

    /// 3×3 homography aligning `moving` to `ref` (source resolution coordinates). With homographic false, translation only.
    static func align(_ moving: CIImage, to ref: CIImage, gainMoving: Double = 1, gainRef: Double = 1, homographic: Bool = true) -> simd_float3x3? {
        guard homographic else { return alignOnce(moving, to: ref, gainMoving: gainMoving, gainRef: gainRef, homographic: false) }
        // With little overlap the homography goes wild → align by translation first, then refine with the homography
        guard let t = alignOnce(moving, to: ref, gainMoving: gainMoving, gainRef: gainRef, homographic: false) else {
            return alignOnce(moving, to: ref, gainMoving: gainMoving, gainRef: gainRef, homographic: true)
        }
        let pre = warp(moving, t)
        guard let h = alignOnce(pre, to: ref, gainMoving: gainMoving, gainRef: gainRef, homographic: true) else { return t }
        // If refinement strays far (misaligned), use translation only
        let c = CGPoint(x: ref.extent.midX, y: ref.extent.midY)
        let p = apply(h, c)
        if hypot(p.x - c.x, p.y - c.y) > max(ref.extent.width, ref.extent.height) * 0.05 { return t }
        return h * t
    }

    private static func alignOnce(_ moving: CIImage, to ref: CIImage, gainMoving: Double, gainRef: Double, homographic: Bool) -> simd_float3x3? {
        // Compare in a region containing both images
        let frame = ref.extent.union(moving.extent).integral
        let (pr, k) = probe(ref, gain: gainRef, frame: frame), (pm, _) = probe(moving, gain: gainMoving, frame: frame)
        // Vision is stable only with CGImages (with CIImages there sometimes was no result)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cr = Render.context.createCGImage(pr, from: pr.extent, format: .RGBA8, colorSpace: space),
              let cm = Render.context.createCGImage(pm, from: pr.extent, format: .RGBA8, colorSpace: space) else { return nil }
        let handler = VNImageRequestHandler(cgImage: cr, options: [:])
        var h: simd_float3x3?
        if homographic {
            let req = VNHomographicImageRegistrationRequest(targetedCGImage: cm, options: [:])
            do { try handler.perform([req]) } catch { if ProcessInfo.processInfo.environment["DUOCHROME_MERGE_DEBUG"] != nil { NSLog("비전 실패 %@", "\(error)") } }
            h = (req.results?.first as? VNImageHomographicAlignmentObservation)?.warpTransform
        } else {
            let req = VNTranslationalImageRegistrationRequest(targetedCGImage: cm, options: [:])
            do { try handler.perform([req]) } catch { if ProcessInfo.processInfo.environment["DUOCHROME_MERGE_DEBUG"] != nil { NSLog("비전 실패 %@", "\(error)") } }
            if let t = (req.results?.first as? VNImageTranslationAlignmentObservation)?.alignmentTransform {
                h = simd_float3x3(SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(Float(t.tx), Float(t.ty), 1))
            }
        }
        guard let hs = h else { return nil }
        // small image coordinates → source: T⁻¹·S⁻¹ · H · S·T (T moves the region origin to 0)
        let kf = Float(k)
        let S = simd_float3x3(diagonal: SIMD3(kf, kf, 1)), Si = simd_float3x3(diagonal: SIMD3(1 / kf, 1 / kf, 1))
        let T = simd_float3x3(SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(-Float(frame.minX), -Float(frame.minY), 1))
        let Ti = simd_float3x3(SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(Float(frame.minX), Float(frame.minY), 1))
        let full = Ti * Si * hs * S * T
        if ProcessInfo.processInfo.environment["DUOCHROME_MERGE_DEBUG"] != nil { NSLog("정렬 H(작은) %@ → %@", "\(hs)", "\(full)") }
        return full
    }

    static func apply(_ h: simd_float3x3, _ p: CGPoint) -> CGPoint {
        let v = h * SIMD3(Float(p.x), Float(p.y), 1)
        return CGPoint(x: CGFloat(v.x / v.z), y: CGFloat(v.y / v.z))
    }

    /// Warps an image by a homography (perspective transform moving the four corners)
    static func warp(_ img: CIImage, _ h: simd_float3x3) -> CIImage {
        let e = img.extent
        let c = [CGPoint(x: e.minX, y: e.maxY), CGPoint(x: e.maxX, y: e.maxY), CGPoint(x: e.maxX, y: e.minY), CGPoint(x: e.minX, y: e.minY)].map { apply(h, $0) }
        return img.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(cgPoint: c[0]), "inputTopRight": CIVector(cgPoint: c[1]),
            "inputBottomRight": CIVector(cgPoint: c[2]), "inputBottomLeft": CIVector(cgPoint: c[3]),
        ])
    }

    /// Aligns all to the first (or middle) frame. Frames that fail to align stay as is.
    static func alignAll(_ frames: [Frame], reference r: Int, homographic: Bool = true, exposureAware: Bool = false) -> [CIImage] {
        let ref = frames[r]
        return frames.enumerated().map { i, f in
            guard i != r else { return f.image }
            let gm = exposureAware ? ref.exposure / f.exposure : 1
            guard let h = align(f.image, to: ref.image, gainMoving: gm, homographic: homographic) else { return f.image }
            return warp(f.image, h).cropped(to: ref.image.extent)
        }
    }

    // MARK: - Multi-input kernels (source generated per frame count, then compiled)

    private static var kernelCache: [String: CIColorKernel] = [:]
    static func kernel(_ key: String, _ source: String) -> CIColorKernel? {
        if let k = kernelCache[key] { return k }
        let k = try? CIColorKernel(source: source)
        kernelCache[key] = k
        return k
    }

    /// HDR: average of exposure-normalized values, weighted by a brightness triangle (near 0 for clipped or too-dark areas)
    static func hdr(_ imgs: [CIImage], exposures: [Double], reference r: Int) -> CIImage? {
        let n = imgs.count
        var src = "kernel vec4 k(" + (0 ..< n).map { "__sample a\($0), float e\($0)" }.joined(separator: ", ") + ") {\n"
        src += "  vec3 acc = vec3(0.0); float ws = 0.0; float best = 1e9; vec3 fallback = vec3(0.0);\n"
        for i in 0 ..< n {
            src += """
              { vec3 c = max(a\(i).rgb, vec3(0.0)); float m = max(c.r, max(c.g, c.b));
                float g = pow(clamp(m, 0.0, 1.0), 1.0 / 2.2);
                float w = (m > 0.97) ? 0.0 : max(1.0 - pow(abs(2.0 * g - 1.0), 6.0), 0.0) + 1e-4;
                acc += w * c / e\(i); ws += w;
                if (m < best) { best = m; fallback = c / e\(i); } }

            """
        }
        src += "  return vec4(ws > 1e-3 ? acc / ws : fallback, 1.0);\n}"
        guard let k = kernel("hdr\(n)", src) else { return nil }
        var args: [Any] = []
        for i in 0 ..< n { args.append(imgs[i]); args.append(exposures[i] / exposures[r]) }
        return k.apply(extent: imgs[r].extent, arguments: args)
    }

    /// Mean (noise reduction)
    static func mean(_ imgs: [CIImage]) -> CIImage? {
        let n = imgs.count
        let src = "kernel vec4 k(" + (0 ..< n).map { "__sample a\($0)" }.joined(separator: ", ") + ") {\n  vec3 s = "
            + (0 ..< n).map { "a\($0).rgb" }.joined(separator: " + ") + ";\n  return vec4(s / \(Float(n)), 1.0);\n}"
        return kernel("mean\(n)", src)?.apply(extent: imgs[0].extent, arguments: imgs)
    }

    /// Median (removes passing people/cars): picks the middle per channel by counting "values smaller than me"
    static func median(_ imgs: [CIImage]) -> CIImage? {
        let n = imgs.count
        var src = "kernel vec4 k(" + (0 ..< n).map { "__sample a\($0)" }.joined(separator: ", ") + ") {\n  vec3 r = vec3(0.0);\n"
        let mid = Float(n - 1) / 2
        for c in ["r", "g", "b"] {
            src += "  { float best = 1e9; float val = a0.\(c);\n"
            for i in 0 ..< n {
                src += "    { float v = a\(i).\(c); float lt = 0.0; float eq = 0.0;\n"
                for j in 0 ..< n where j != i { src += "      lt += step(a\(j).\(c), v - 1e-7); eq += step(abs(a\(j).\(c) - v), 1e-7);\n" }
                // distance 0 if v has the middle rank (lt ≤ mid ≤ lt+eq)
                src += "      float d = max(lt - \(mid), 0.0) + max(\(mid) - (lt + eq), 0.0); if (d < best) { best = d; val = v; } }\n"
            }
            src += "    r.\(c) = val; }\n"
        }
        src += "  return vec4(r, 1.0);\n}"
        return kernel("median\(n)", src)?.apply(extent: imgs[0].extent, arguments: imgs)
    }

    static let sharpK = CIColorKernel(source: """
        kernel vec4 k(__sample l) { float v = abs(dot(l.rgb, vec3(0.3, 0.59, 0.11)) - 0.5); return vec4(v, v, v, 1.0); }
        """)

    /// Focus stacking: weight is the 4th power of a sharpness map (blurred magnitude of the luminance Laplacian)
    static func focusStack(_ imgs: [CIImage], scale: CGFloat) -> CIImage? {
        let n = imgs.count
        let maps: [CIImage] = imgs.map { img in
            let g = img.applyingFilter("CILinearToSRGBToneCurve")
            let lap = g.applyingFilter("CIConvolution3X3", parameters: [
                "inputWeights": CIVector(values: [0, 1, 0, 1, -4, 1, 0, 1, 0], count: 9), "inputBias": 0.5])
            let mag = sharpK?.apply(extent: img.extent, arguments: [lap]) ?? lap
            return mag.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(6 * scale, 1.5)]).cropped(to: img.extent)
        }
        var src = "kernel vec4 k(" + (0 ..< n).map { "__sample a\($0), __sample s\($0)" }.joined(separator: ", ") + ") {\n  vec3 acc = vec3(0.0); float ws = 0.0;\n"
        for i in 0 ..< n { src += "  { float w = pow(s\(i).r * 20.0, 4.0) + 1e-6; acc += w * a\(i).rgb; ws += w; }\n" }
        src += "  return vec4(acc / ws, 1.0);\n}"
        var args: [Any] = []
        for i in 0 ..< n { args.append(imgs[i]); args.append(maps[i]) }
        return kernel("focus\(n)", src)?.apply(extent: imgs[0].extent, arguments: args)
    }

    // MARK: - Panorama

    enum Projection: Int, CaseIterable { case planar, cylindrical, spherical
        var title: String { ["직선 (원근)", "원통", "구면"][rawValue] }
    }

    /// Unwraps to cylindrical/spherical (inverse: result coordinates → source). f is focal length in pixels, center is the optical axis.
    static let cylK = try? CIKernel(source: """
        kernel vec4 k(sampler s, vec2 c, float f, float sph) {
            vec2 d = destCoord() - c;
            float th = d.x / f;
            float x = f * tan(th);
            float r = sqrt(x * x + f * f);
            float y = sph > 0.5 ? r * tan(d.y / f) : d.y * r / f;
            if (abs(th) > 1.55) return vec4(0.0);
            vec2 p = c + vec2(x, y);
            return sample(s, samplerTransform(s, p));
        }
        """)

    static func project(_ img: CIImage, f: CGFloat, spherical: Bool) -> CIImage {
        let e = img.extent
        let c = CGPoint(x: e.midX, y: e.midY)
        let halfW = f * atan(e.width / 2 / f)
        let halfH = spherical ? f * atan(e.height / 2 / f) : e.height / 2
        let out = CGRect(x: c.x - halfW, y: c.y - halfH, width: halfW * 2, height: halfH * 2).integral
        guard let k = cylK else { return img }
        // Transparent outside (alpha carries the weight)
        let src = img.cropped(to: e)
        return k.apply(extent: out, roiCallback: { _, _ in e }, arguments: [src, CIVector(cgPoint: c), f, spherical ? 1 : 0]) ?? img
    }

    /// Image with a weight falling to 0 at the edges baked (multiplied) into alpha
    static let featherK = CIColorKernel(source: """
        kernel vec4 k(__sample s, vec4 box, float fw) {
            vec2 p = destCoord();
            float wx = clamp(min(p.x - box.x, box.z - p.x) / fw, 0.0, 1.0);
            float wy = clamp(min(p.y - box.y, box.w - p.y) / fw, 0.0, 1.0);
            float w = wx * wy * s.a + 1e-5 * s.a;
            return vec4(s.rgb * w, w);
        }
        """)

    static func feathered(_ img: CIImage, width fw: CGFloat) -> CIImage {
        let e = img.extent
        return featherK?.apply(extent: e, arguments: [img, CIVector(x: e.minX, y: e.minY, z: e.maxX, w: e.maxY), max(fw, 1)]) ?? img
    }

    /// Divides by the weight sum; areas without photos become transparent
    static let normalizeK = CIColorKernel(source: """
        kernel vec4 k(__sample s) { return s.a > 1e-4 ? vec4(s.rgb / s.a, 1.0) : vec4(0.0); }
        """)

    /// Adds alpha as is without blending (CIAdditionCompositing clamps alpha to 1)
    static let addK = CIColorKernel(source: "kernel vec4 k(__sample a, __sample b) { return a + b; }")

    static func panorama(_ frames: [Frame], projection: Projection, scale: CGFloat) throws -> CIImage {
        let n = frames.count
        guard n >= 2 else { throw Failure(message: "두 장 이상 고르세요") }
        let W = frames[0].image.extent.width
        let f35 = frames[0].focal35 ?? 35
        let fpx = CGFloat(f35 / 36) * max(W, frames[0].image.extent.height)
        var placed: [CIImage] = []
        switch projection {
        case .planar:
            // Homographies between neighbors → chained relative to the middle frame
            let mid = n / 2
            var toMid = [simd_float3x3](repeating: matrix_identity_float3x3, count: n)
            for i in stride(from: mid - 1, through: 0, by: -1) {
                guard let h = align(frames[i].image, to: frames[i + 1].image) else { throw Failure(message: "\(frames[i].url.lastPathComponent)을 이웃과 맞추지 못했습니다") }
                toMid[i] = toMid[i + 1] * h
            }
            for i in (mid + 1) ..< n {
                guard let h = align(frames[i].image, to: frames[i - 1].image) else { throw Failure(message: "\(frames[i].url.lastPathComponent)을 이웃과 맞추지 못했습니다") }
                toMid[i] = toMid[i - 1] * h
            }
            placed = frames.enumerated().map { i, fr in warp(feathered(fr.image, width: W * 0.15), toMid[i]) }
        case .cylindrical, .spherical:
            let sph = projection == .spherical
            let flat = frames.map { project($0.image, f: fpx, spherical: sph) }
            // Measure translation between unwrapped photos (more stable), convert to rotation angles, and place on the cylinder
            var offsets: [CGPoint] = [.zero]
            for i in 1 ..< n {
                guard let h = align(frames[i].image, to: frames[i - 1].image, homographic: false) else { throw Failure(message: "\(frames[i].url.lastPathComponent)을 이웃과 맞추지 못했습니다") }
                let tx = CGFloat(h[2][0]), ty = CGFloat(h[2][1])
                let dx = fpx * atan(tx / fpx)
                let dy = sph ? fpx * atan(ty / fpx) : ty
                offsets.append(CGPoint(x: offsets[i - 1].x + dx, y: offsets[i - 1].y + dy))
            }
            placed = flat.enumerated().map { i, img in
                feathered(img, width: img.extent.width * 0.15).transformed(by: .init(translationX: offsets[i].x, y: offsets[i].y))
            }
        }
        guard let add = addK, let norm = normalizeK else { throw Failure(message: "합치기 커널을 만들지 못했습니다") }
        let bounds = placed.map(\.extent).reduce(CGRect.null) { $0.union($1) }.integral
        var acc = CIImage(color: .clear).cropped(to: bounds)
        for p in placed {
            let full = p.composited(over: CIImage(color: .clear).cropped(to: bounds)).cropped(to: bounds)
            acc = add.apply(extent: bounds, arguments: [acc, full]) ?? acc
        }
        return (norm.apply(extent: bounds, arguments: [acc]) ?? acc)
    }

    /// Trims the jagged top/bottom edges (the largest horizontal band where every column has photo)
    static func autoCrop(_ img: CIImage) -> CIImage {
        let e = img.extent
        let k = min(1, 800 / max(e.width, e.height))
        let small = img.transformed(by: .init(scaleX: k, y: k))
        let r = small.extent.integral
        let w = Int(r.width), h = Int(r.height)
        guard w > 2, h > 2 else { return img }
        var px = [Float](repeating: 0, count: w * h * 4)
        Render.context.render(small, toBitmap: &px, rowBytes: w * 16, bounds: r, format: .RGBAf, colorSpace: nil)
        // fraction of filled alpha per row
        func rowFull(_ y: Int) -> Bool { (0 ..< w).allSatisfy { px[(y * w + $0) * 4 + 3] > 0.5 } }
        func colFull(_ x: Int, _ y0: Int, _ y1: Int) -> Bool { (y0 ... y1).allSatisfy { px[($0 * w + x) * 4 + 3] > 0.5 } }
        // Grow up/down from the middle row (trimming sides horizontally)
        var x0 = 0, x1 = w - 1
        let cy = h / 2
        while x0 < x1, !colFull(x0, cy, cy) { x0 += 1 }
        while x1 > x0, !colFull(x1, cy, cy) { x1 -= 1 }
        var y0 = cy, y1 = cy
        func rowOK(_ y: Int) -> Bool { (x0 ... x1).allSatisfy { px[(y * w + $0) * 4 + 3] > 0.5 } }
        while y0 > 0, rowOK(y0 - 1) { y0 -= 1 }
        while y1 < h - 1, rowOK(y1 + 1) { y1 += 1 }
        _ = rowFull
        // bitmap rows from the top
        let crop = CGRect(x: r.minX + CGFloat(x0) / 1, y: r.minY + CGFloat(h - 1 - y1), width: CGFloat(x1 - x0 + 1), height: CGFloat(y1 - y0 + 1))
        let full = CGRect(x: crop.minX / k, y: crop.minY / k, width: crop.width / k, height: crop.height / k).integral.insetBy(dx: 2, dy: 2)
        return img.cropped(to: full)
    }

    // MARK: - Writing the result

    /// Linear image → DNG. Values above 1 (HDR) are divided by the max and recorded so BaselineExposure restores them.
    static func writeDNG(_ img: CIImage, to url: URL, camera: String) throws {
        let e = img.extent.integral
        let moved = img.cropped(to: e).transformed(by: .init(translationX: -e.minX, y: -e.minY))
        // map the bright 99.9% value to 1
        let k = min(1, 512 / max(e.width, e.height))
        let small = moved.transformed(by: .init(scaleX: k, y: k))
        let sr = small.extent.integral
        var px = [Float](repeating: 0, count: Int(sr.width) * Int(sr.height) * 4)
        Render.context.render(small, toBitmap: &px, rowBytes: Int(sr.width) * 16, bounds: sr, format: .RGBAf, colorSpace: DNGWriter.linearProPhoto)
        var maxes = stride(from: 0, to: px.count, by: 4).map { max(px[$0], px[$0 + 1], px[$0 + 2]) }
        maxes.sort()
        let top = Double(maxes[min(maxes.count - 1, Int(Double(maxes.count) * 0.999))])
        let gain = top > 1 ? 1 / top : 1
        let scaled = gain < 1 ? moved.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: log2(gain)]) : moved
        try DNGWriter.write(image: scaled, to: url, camera: camera, baselineExposure: -log2(gain))
    }

    static func outputURL(_ first: URL, suffix: String) -> URL {
        let dir = first.deletingLastPathComponent()
        var u = dir.appendingPathComponent(first.deletingPathExtension().lastPathComponent + "-" + suffix + ".dng")
        var n = 2
        while FileManager.default.fileExists(atPath: u.path) {
            u = dir.appendingPathComponent(first.deletingPathExtension().lastPathComponent + "-" + suffix + "-\(n).dng"); n += 1
        }
        return u
    }
}
