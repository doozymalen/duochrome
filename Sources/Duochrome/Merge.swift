import AppKit
import CoreImage
import ImageIO
import Vision
import simd

/// 여러 장 합치기: HDR, 파노라마(직선·원통·구면), 초점 스태킹, 이미지 스택(중앙값·평균).
/// 모두 RAW를 선형(톤 곡선·기본 모습 끔)으로 풀어 맞추고 합친 뒤, 결과를 16비트 선형 DNG로 쓴다
/// (다시 RAW처럼 노출·화이트 밸런스를 만질 수 있다).
enum Merge {
    struct Frame {
        var url: URL
        var image: CIImage          // 작업 공간 선형
        var exposure: Double        // 노출 인자 t·ISO/N² (상대 비교용)
        var focal35: Double?        // 35mm 환산 초점 거리
        var camera: String
    }

    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    // MARK: - 불러오기

    static func exposureFactor(_ url: URL) -> (Double, Double?) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] else { return (1, nil) }
        let t = exif[kCGImagePropertyExifExposureTime] as? Double ?? 1
        let n = exif[kCGImagePropertyExifFNumber] as? Double ?? 1
        let iso = Double((exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first ?? exif[kCGImagePropertyExifISOSpeed] as? Int
                         ?? exif[kCGImagePropertyExifRecommendedExposureIndex] as? Int ?? 100)
        var f35 = (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Double).flatMap { $0 > 0 ? $0 : nil }
        if f35 == nil, let f = exif[kCGImagePropertyExifFocalLength] as? Double { f35 = f }   // 풀프레임 가정
        return (t * iso / max(n * n, 0.01), f35)
    }

    /// 선형으로 푼 그림 (scale: 1이면 원본 해상도)
    static func load(_ url: URL, scale: CGFloat) throws -> Frame {
        let doc = try RawDocument(url: url)
        var s = doc.asShot
        s.filmCurve = 0          // 톤 곡선 끔 → 장면 선형
        s.look = 0
        s.highlightRecoveryOn = false
        doc.settings = s
        doc.usePreviewCache = false
        let (e, f35) = exposureFactor(url)
        return Frame(url: url, image: doc.image(scale: scale), exposure: e, focal35: f35, camera: doc.info.camera)
    }

    // MARK: - 맞추기 (Vision)

    /// 맞추기용 작은 그림 (감마, 밝기 맞춤)
    /// frame: 두 그림이 같은 좌표를 쓰도록 기준 그림의 영역 (원점을 0으로 옮기고 줄인다)
    static func probe(_ img: CIImage, gain: Double, frame: CGRect, long: CGFloat = 1600) -> (CIImage, CGFloat) {
        let k = min(1, long / max(frame.width, frame.height))
        let g = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: log2(max(gain, 1e-6))])
            .applyingFilter("CIColorClamp").applyingFilter("CILinearToSRGBToneCurve")
            .composited(over: CIImage(color: .black).cropped(to: frame)).cropped(to: frame)
        let small = g.transformed(by: .init(translationX: -frame.minX, y: -frame.minY)).transformed(by: .init(scaleX: k, y: k))
        return (small.cropped(to: CGRect(x: 0, y: 0, width: (frame.width * k).rounded(.down), height: (frame.height * k).rounded(.down))), k)
    }

    /// `moving`을 `ref`에 맞추는 3×3 호모그래피 (원래 해상도 좌표). homographic false면 평행 이동만.
    static func align(_ moving: CIImage, to ref: CIImage, gainMoving: Double = 1, gainRef: Double = 1, homographic: Bool = true) -> simd_float3x3? {
        guard homographic else { return alignOnce(moving, to: ref, gainMoving: gainMoving, gainRef: gainRef, homographic: false) }
        // 겹침이 적으면 호모그래피가 엉뚱하게 나온다 → 평행 이동으로 먼저 대고 호모그래피로 다듬는다
        guard let t = alignOnce(moving, to: ref, gainMoving: gainMoving, gainRef: gainRef, homographic: false) else {
            return alignOnce(moving, to: ref, gainMoving: gainMoving, gainRef: gainRef, homographic: true)
        }
        let pre = warp(moving, t)
        guard let h = alignOnce(pre, to: ref, gainMoving: gainMoving, gainRef: gainRef, homographic: true) else { return t }
        // 다듬기가 크게 벗어나면 (잘못 맞춘 것) 평행 이동만 쓴다
        let c = CGPoint(x: ref.extent.midX, y: ref.extent.midY)
        let p = apply(h, c)
        if hypot(p.x - c.x, p.y - c.y) > max(ref.extent.width, ref.extent.height) * 0.05 { return t }
        return h * t
    }

    private static func alignOnce(_ moving: CIImage, to ref: CIImage, gainMoving: Double, gainRef: Double, homographic: Bool) -> simd_float3x3? {
        // 두 그림을 모두 담는 영역에서 비교한다
        let frame = ref.extent.union(moving.extent).integral
        let (pr, k) = probe(ref, gain: gainRef, frame: frame), (pm, _) = probe(moving, gain: gainMoving, frame: frame)
        // 비전은 CGImage로 넘겨야 안정적이다 (CIImage 그대로면 결과가 없을 때가 있었다)
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
        // 작은 그림 좌표 → 원래 좌표: T⁻¹·S⁻¹ · H · S·T (T는 영역 원점을 0으로)
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

    /// 호모그래피로 그림을 옮긴다 (네 모서리를 옮기는 원근 변환)
    static func warp(_ img: CIImage, _ h: simd_float3x3) -> CIImage {
        let e = img.extent
        let c = [CGPoint(x: e.minX, y: e.maxY), CGPoint(x: e.maxX, y: e.maxY), CGPoint(x: e.maxX, y: e.minY), CGPoint(x: e.minX, y: e.minY)].map { apply(h, $0) }
        return img.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(cgPoint: c[0]), "inputTopRight": CIVector(cgPoint: c[1]),
            "inputBottomRight": CIVector(cgPoint: c[2]), "inputBottomLeft": CIVector(cgPoint: c[3]),
        ])
    }

    /// 첫 장(또는 가운데 장)을 기준으로 모두 맞춘다. 맞추지 못한 장은 그대로 둔다.
    static func alignAll(_ frames: [Frame], reference r: Int, homographic: Bool = true, exposureAware: Bool = false) -> [CIImage] {
        let ref = frames[r]
        return frames.enumerated().map { i, f in
            guard i != r else { return f.image }
            let gm = exposureAware ? ref.exposure / f.exposure : 1
            guard let h = align(f.image, to: ref.image, gainMoving: gm, homographic: homographic) else { return f.image }
            return warp(f.image, h).cropped(to: ref.image.extent)
        }
    }

    // MARK: - 여러 입력 커널 (장 수만큼 글을 만들어 컴파일)

    private static var kernelCache: [String: CIColorKernel] = [:]
    static func kernel(_ key: String, _ source: String) -> CIColorKernel? {
        if let k = kernelCache[key] { return k }
        let k = try? CIColorKernel(source: source)
        kernelCache[key] = k
        return k
    }

    /// HDR: 밝기 삼각 무게(날아간 곳·너무 어두운 곳은 거의 0)로 노출을 나눈 값을 평균
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

    /// 평균 (노이즈 줄이기)
    static func mean(_ imgs: [CIImage]) -> CIImage? {
        let n = imgs.count
        let src = "kernel vec4 k(" + (0 ..< n).map { "__sample a\($0)" }.joined(separator: ", ") + ") {\n  vec3 s = "
            + (0 ..< n).map { "a\($0).rgb" }.joined(separator: " + ") + ";\n  return vec4(s / \(Float(n)), 1.0);\n}"
        return kernel("mean\(n)", src)?.apply(extent: imgs[0].extent, arguments: imgs)
    }

    /// 중앙값 (지나가는 사람·차 지우기): 채널마다 "나보다 작은 값의 개수"로 가운데를 고른다
    static func median(_ imgs: [CIImage]) -> CIImage? {
        let n = imgs.count
        var src = "kernel vec4 k(" + (0 ..< n).map { "__sample a\($0)" }.joined(separator: ", ") + ") {\n  vec3 r = vec3(0.0);\n"
        let mid = Float(n - 1) / 2
        for c in ["r", "g", "b"] {
            src += "  { float best = 1e9; float val = a0.\(c);\n"
            for i in 0 ..< n {
                src += "    { float v = a\(i).\(c); float lt = 0.0; float eq = 0.0;\n"
                for j in 0 ..< n where j != i { src += "      lt += step(a\(j).\(c), v - 1e-7); eq += step(abs(a\(j).\(c) - v), 1e-7);\n" }
                // v가 가운데 순위(lt ≤ mid ≤ lt+eq)면 거리 0
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

    /// 초점 스태킹: 선명도 지도(밝기 라플라시안의 크기를 흐린 것)의 네제곱을 무게로
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

    // MARK: - 파노라마

    enum Projection: Int, CaseIterable { case planar, cylindrical, spherical
        var title: String { ["직선 (원근)", "원통", "구면"][rawValue] }
    }

    /// 원통·구면으로 편다 (역방향: 결과 좌표 → 원본 좌표). f는 픽셀 초점 거리, 가운데가 광축.
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
        // 바깥은 투명 (알파로 무게를 나른다)
        let src = img.cropped(to: e)
        return k.apply(extent: out, roiCallback: { _, _ in e }, arguments: [src, CIVector(cgPoint: c), f, spherical ? 1 : 0]) ?? img
    }

    /// 가장자리로 갈수록 0이 되는 무게를 알파에 넣은 (곱한) 그림
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

    /// 무게 합으로 나누고 사진이 없는 곳은 투명으로
    static let normalizeK = CIColorKernel(source: """
        kernel vec4 k(__sample s) { return s.a > 1e-4 ? vec4(s.rgb / s.a, 1.0) : vec4(0.0); }
        """)

    /// 알파 채널을 섞지 않고 그대로 더한다 (CIAdditionCompositing은 알파를 1로 막는다)
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
            // 이웃끼리 호모그래피 → 가운데 장 기준으로 잇는다
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
            // 펴기 전 사진끼리 평행 이동을 재고(더 안정적) 회전각으로 바꿔 원통 위 자리로 옮긴다
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

    /// 위아래 들쭉날쭉한 가장자리를 잘라 낸다 (모든 열에 사진이 있는 가장 큰 가로 띠)
    static func autoCrop(_ img: CIImage) -> CIImage {
        let e = img.extent
        let k = min(1, 800 / max(e.width, e.height))
        let small = img.transformed(by: .init(scaleX: k, y: k))
        let r = small.extent.integral
        let w = Int(r.width), h = Int(r.height)
        guard w > 2, h > 2 else { return img }
        var px = [Float](repeating: 0, count: w * h * 4)
        Render.context.render(small, toBitmap: &px, rowBytes: w * 16, bounds: r, format: .RGBAf, colorSpace: nil)
        // 행마다 알파가 찬 비율
        func rowFull(_ y: Int) -> Bool { (0 ..< w).allSatisfy { px[(y * w + $0) * 4 + 3] > 0.5 } }
        func colFull(_ x: Int, _ y0: Int, _ y1: Int) -> Bool { (y0 ... y1).allSatisfy { px[($0 * w + x) * 4 + 3] > 0.5 } }
        // 가운데 행부터 위·아래로 넓힌다 (가로는 좌우로 잘라가며)
        var x0 = 0, x1 = w - 1
        let cy = h / 2
        while x0 < x1, !colFull(x0, cy, cy) { x0 += 1 }
        while x1 > x0, !colFull(x1, cy, cy) { x1 -= 1 }
        var y0 = cy, y1 = cy
        func rowOK(_ y: Int) -> Bool { (x0 ... x1).allSatisfy { px[(y * w + $0) * 4 + 3] > 0.5 } }
        while y0 > 0, rowOK(y0 - 1) { y0 -= 1 }
        while y1 < h - 1, rowOK(y1 + 1) { y1 += 1 }
        _ = rowFull
        // 비트맵은 위 줄부터
        let crop = CGRect(x: r.minX + CGFloat(x0) / 1, y: r.minY + CGFloat(h - 1 - y1), width: CGFloat(x1 - x0 + 1), height: CGFloat(y1 - y0 + 1))
        let full = CGRect(x: crop.minX / k, y: crop.minY / k, width: crop.width / k, height: crop.height / k).integral.insetBy(dx: 2, dy: 2)
        return img.cropped(to: full)
    }

    // MARK: - 결과 쓰기

    /// 선형 그림 → DNG. 1을 넘는 값(HDR)은 최대값으로 나누고 기준 노출(BaselineExposure)로 되돌리게 적는다.
    static func writeDNG(_ img: CIImage, to url: URL, camera: String) throws {
        let e = img.extent.integral
        let moved = img.cropped(to: e).transformed(by: .init(translationX: -e.minX, y: -e.minY))
        // 밝은 쪽 99.9% 값을 1로
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
