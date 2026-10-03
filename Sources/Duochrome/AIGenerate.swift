import AppKit
import CoreImage

// MARK: - AI stages 2–3: via the invisible AI engine — remove/smart erase, generative fill/expand, denoise, 2× upscale
// Send only the needed crop, not the whole photo; results go to a new layer (original untouched, undoable).

enum AIWorkflows {
    static let checkpoint = "RealVisXL_V5.0_fp16.safetensors"
    static let negative = "blurry, lowres, text, watermark, logo, signature, deformed, cartoon, painting, frame, border"

    /// Erase (fill painted area naturally from its surroundings)
    static func remove(image: String, mask: String) -> [String: Any] {
        [
            "1": ["class_type": "LoadImage", "inputs": ["image": image]],
            "2": ["class_type": "LoadImageMask", "inputs": ["image": mask, "channel": "red"]],
            "3": ["class_type": "INPAINT_LoadInpaintModel", "inputs": ["model_name": "big-lama.pt"]],
            "4": ["class_type": "DuochromeLaMa", "inputs": ["inpaint_model": ["3", 0], "image": ["1", 0], "mask": ["2", 0]]],
            "5": ["class_type": "SaveImage", "inputs": ["images": ["4", 0], "filename_prefix": "duochrome"]],
        ]
    }

    /// Generative fill (photoreal model + fast 8 steps + inpaint helper)
    static func fill(image: String, mask: String, prompt: String, seed: Int, steps: Int = 8) -> [String: Any] {
        [
            "1": ["class_type": "CheckpointLoaderSimple", "inputs": ["ckpt_name": checkpoint]],
            "2": ["class_type": "LoraLoaderModelOnly", "inputs": ["model": ["1", 0], "lora_name": "sdxl_lightning_8step_lora.safetensors", "strength_model": 1.0]],
            "3": ["class_type": "CLIPTextEncode", "inputs": ["text": prompt.isEmpty ? "photo, natural continuation of the surroundings, same lighting" : prompt, "clip": ["1", 1]]],
            "4": ["class_type": "CLIPTextEncode", "inputs": ["text": negative, "clip": ["1", 1]]],
            "5": ["class_type": "LoadImage", "inputs": ["image": image]],
            "6": ["class_type": "LoadImageMask", "inputs": ["image": mask, "channel": "red"]],
            "7": ["class_type": "INPAINT_ExpandMask", "inputs": ["mask": ["6", 0], "grow": 8, "blur": 8, "blur_type": "gaussian"]],
            "8": ["class_type": "INPAINT_MaskedFill", "inputs": ["image": ["5", 0], "mask": ["7", 0], "fill": "telea", "falloff": 0]],
            "9": ["class_type": "INPAINT_VAEEncodeInpaintConditioning", "inputs": ["positive": ["3", 0], "negative": ["4", 0], "vae": ["1", 2], "pixels": ["8", 0], "mask": ["7", 0]]],
            "10": ["class_type": "INPAINT_LoadFooocusInpaint", "inputs": ["head": "fooocus_inpaint_head.pth", "patch": "inpaint_v26.fooocus.patch"]],
            "11": ["class_type": "INPAINT_ApplyFooocusInpaint", "inputs": ["model": ["2", 0], "patch": ["10", 0], "latent": ["9", 2]]],
            "12": ["class_type": "KSampler", "inputs": ["model": ["11", 0], "positive": ["9", 0], "negative": ["9", 1], "latent_image": ["9", 3],
                                                  "seed": seed, "steps": steps, "cfg": 1.5, "sampler_name": "euler", "scheduler": "sgm_uniform", "denoise": 1.0]],
            "13": ["class_type": "VAEDecode", "inputs": ["samples": ["12", 0], "vae": ["1", 2]]],
            "14": ["class_type": "SaveImage", "inputs": ["images": ["13", 0], "filename_prefix": "duochrome"]],
        ]
    }

    /// FLUX Fill (Colab): best fill/expand quality among open models. Loaded in 8-bit on L4/T4 to fit memory
    static func fluxFill(image: String, mask: String, prompt: String, seed: Int, steps: Int = 24, fp8: Bool) -> [String: Any] {
        [
            "1": ["class_type": "UNETLoader", "inputs": ["unet_name": "flux1-fill-dev.safetensors", "weight_dtype": fp8 ? "fp8_e4m3fn" : "default"]],
            "2": ["class_type": "DualCLIPLoader", "inputs": ["clip_name1": "clip_l.safetensors", "clip_name2": "t5xxl_fp8_e4m3fn.safetensors", "type": "flux"]],
            "3": ["class_type": "VAELoader", "inputs": ["vae_name": "ae.safetensors"]],
            "4": ["class_type": "CLIPTextEncode", "inputs": ["text": prompt.isEmpty ? "photo, seamless natural continuation of the surroundings, same lighting and texture" : prompt, "clip": ["2", 0]]],
            "5": ["class_type": "FluxGuidance", "inputs": ["conditioning": ["4", 0], "guidance": 30.0]],
            "6": ["class_type": "ConditioningZeroOut", "inputs": ["conditioning": ["4", 0]]],
            "7": ["class_type": "LoadImage", "inputs": ["image": image]],
            "8": ["class_type": "LoadImageMask", "inputs": ["image": mask, "channel": "red"]],
            "9": ["class_type": "GrowMask", "inputs": ["mask": ["8", 0], "expand": 6, "tapered_corners": true]],
            "10": ["class_type": "InpaintModelConditioning", "inputs": ["positive": ["5", 0], "negative": ["6", 0], "vae": ["3", 0], "pixels": ["7", 0], "mask": ["9", 0], "noise_mask": true]],
            "11": ["class_type": "DifferentialDiffusion", "inputs": ["model": ["1", 0]]],
            "12": ["class_type": "KSampler", "inputs": ["model": ["11", 0], "positive": ["10", 0], "negative": ["10", 1], "latent_image": ["10", 2],
                                                  "seed": seed, "steps": steps, "cfg": 1.0, "sampler_name": "euler", "scheduler": "normal", "denoise": 1.0]],
            "13": ["class_type": "VAEDecode", "inputs": ["samples": ["12", 0], "vae": ["3", 0]]],
            "14": ["class_type": "SaveImage", "inputs": ["images": ["13", 0], "filename_prefix": "duochrome"]],
        ]
    }

    /// Reflection removal (DSIT, Duochrome custom node)
    static func reflection(image: String) -> [String: Any] {
        [
            "1": ["class_type": "LoadImage", "inputs": ["image": image]],
            "2": ["class_type": "DuochromeReflection", "inputs": ["image": ["1", 0]]],
            "3": ["class_type": "SaveImage", "inputs": ["images": ["2", 0], "filename_prefix": "duochrome"]],
        ]
    }

    /// Image processing with a single model (denoise 1×, upscale 2×). The engine tiles the work
    static func imageModel(image: String, model: String) -> [String: Any] {
        [
            "1": ["class_type": "LoadImage", "inputs": ["image": image]],
            "2": ["class_type": "UpscaleModelLoader", "inputs": ["model_name": model]],
            "3": ["class_type": "ImageUpscaleWithModel", "inputs": ["upscale_model": ["2", 0], "image": ["1", 0]]],
            "4": ["class_type": "SaveImage", "inputs": ["images": ["3", 0], "filename_prefix": "duochrome"]],
        ]
    }
}

enum AIRegion {
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Bounding box of the white area in a grayscale mask (source coordinates)
    static func bounds(of mask: CIImage) -> CGRect? {
        let e = mask.extent
        let k = min(1, 512 / max(e.width, e.height))
        let small = mask.transformed(by: .init(scaleX: k, y: k))
        let r = small.extent.integral
        let w = Int(r.width), h = Int(r.height)
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h)
        Render.context.render(small, toBitmap: &px, rowBytes: w, bounds: r, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w where px[y * w + x] > 20 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= 0 else { return nil }
        // Memory row 0 is the top → coordinates with bottom at 0
        return CGRect(x: CGFloat(minX) / k + e.minX, y: CGFloat(h - 1 - maxY) / k + e.minY,
                      width: CGFloat(maxX - minX + 1) / k, height: CGFloat(maxY - minY + 1) / k)
    }

    /// Bounding box of brush points and brush size (without rendering)
    static func strokeBounds(_ strokes: [MaskStroke]) -> CGRect? {
        var r: CGRect?
        for s in strokes {
            let rad = CGFloat(s.radius)
            for i in stride(from: 0, to: s.points.count - 1, by: 2) {
                let b = CGRect(x: CGFloat(s.points[i]) - rad, y: CGFloat(s.points[i + 1]) - rad, width: rad * 2, height: rad * 2)
                r = r.map { $0.union(b) } ?? b
            }
        }
        return r
    }

    /// Saves a source-coordinate grayscale mask (may cover only part; missing areas are black) at quarter size into the layer image folder.
    /// Image masks are upscaled to source size on load, so there's no reason to store full size (8K photo: seconds → tens of ms)
    static func storeMask(_ m: CIImage, native n: CGSize) -> String? {
        let k: CGFloat = 0.25
        let size = CGRect(x: 0, y: 0, width: (n.width * k).rounded(), height: (n.height * k).rounded())
        let img = m.composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: n)))
            .transformed(by: .init(scaleX: size.width / n.width, y: size.height / n.height)).cropped(to: size)
        guard let png = Render.context.pngRepresentation(of: img, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) else { return nil }
        return try? LayerImageStore.importData(png, ext: "png")
    }

    /// Non-blocking notice: shown in the jobs panel for a few seconds
    static func notice(_ title: String, _ detail: String) {
        let key = "notice-\(UUID().uuidString)"
        JobCenter.shared.begin(key, title: title, detail: detail)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { JobCenter.shared.end(key) }
    }

    /// Very high quality JPEG (when sending the whole source to Colab)
    static func jpeg(_ img: CIImage) -> Data? {
        Render.context.jpegRepresentation(of: img, colorSpace: srgb, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.97])
    }

    static func png(_ img: CIImage, gray: Bool = false) -> Data? {
        let r = img.extent
        return gray ? Render.context.pngRepresentation(of: img, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
                    : Render.context.pngRepresentation(of: img.cropped(to: r), format: .RGBA8, colorSpace: srgb)
    }

    /// Moves a crop to the origin and limits the long side to `limit` (multiple of 8)
    static func prepare(_ img: CIImage, region r: CGRect, limit: CGFloat) -> (CIImage, CGFloat) {
        var k = min(1, limit / max(r.width, r.height))
        let w = max(8, (r.width * k / 8).rounded() * 8), h = max(8, (r.height * k / 8).rounded() * 8)
        k = w / r.width
        let moved = img.cropped(to: r).transformed(by: .init(translationX: -r.minX, y: -r.minY))
        let scaled = k < 0.999 ? moved.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: h / r.height, kCIInputAspectRatioKey: k / (h / r.height)]) : moved
        return (scaled.cropped(to: CGRect(x: 0, y: 0, width: w, height: h)), k)
    }
}

extension MainWindowController {
    // MARK: Shared: run engine work in the background and turn results into layers

    /// Heavy generative work: Colab (L4 by default) or the local engine per settings. inputs: (name, data); the workflow references those names
    static func heavyAI(_ title: String, inputs: [(String, Data)], jpeg: Bool = false,
                        remote: (_ fp8: Bool) -> [String: Any], local: (_ names: [String]) -> [String: Any]) throws -> Data {
        if AIRemote.current != .local, ColabEngine.shared.usable {
            let c = ColabEngine.shared
            do {
                // The GPU is only known after starting, so 8-bit follows the requested GPU (only A100 at full precision)
                return try c.run(remote(AIRemote.current != .colabA100 || c.gpu == "T4"), inputs: inputs, title: title, jpeg: jpeg)
            } catch {
                // Colab by default, local as fallback: if Colab fails, continue on the local engine
                c.markUnavailable(error.localizedDescription)
                AIRegion.notice("코랩 연결 안 됨 → 이 맥에서 \(title)", error.localizedDescription)
                JobCenter.shared.detail("ai-\(title)", "이 맥에서 처리 중 (코랩 안 됨)")
            }
        }
        let e = AIEngine.shared
        try e.ensureRunning()
        let names = try inputs.map { try e.upload($0.1, name: "duochrome-\($0.0)") }
        guard let out = try e.run(local(names), title: title).first else { throw AIEngine.Failure(message: "결과 그림이 없음") }
        e.freeMemory()
        return out
    }

    /// End of the photo stack the AI sees: up to below the first text/shape layer (text and shapes draw in view coordinates separately,
    /// so baking them into the result misaligned them. Layers above stay on top of the result)
    var aiLayerCut: Int {
        let ls = photo?.settings.layers ?? []
        return ls.firstIndex { $0.kind == "text" || $0.kind == "shape" } ?? ls.count
    }

    /// Full-size composite in source coordinates (up to the photo-stack layers, no geometry corrections)
    func nativeComposite() -> CIImage? { rasterize(Array((photo?.settings.layers ?? []).prefix(aiLayerCut)), withPhoto: true) }

    /// Inserts the result crop (at r in source coordinates) as an image layer, showing only the mask shape if a mask (source grayscale) is given
    func placeAIResult(_ result: CIImage, region r: CGRect, name: String, mask: String?) {
        guard var s = photo?.settings else { return }
        let fitted = result.transformed(by: .init(scaleX: r.width / result.extent.width, y: r.height / result.extent.height))
        guard let png = AIRegion.png(fitted.transformed(by: .init(translationX: -fitted.extent.minX, y: -fitted.extent.minY))
                                        .cropped(to: CGRect(x: 0, y: 0, width: r.width.rounded(), height: r.height.rounded()))),
              let file = try? LayerImageStore.importData(png, ext: "png") else { NSSound.beep(); return }
        var l = AdjustLayer(name: "\(name) \(s.layers.count + 1)")
        l.kind = "image"
        l.image = LayerImage(file: file, cx: Double(r.midX), cy: Double(r.midY), width: Double(r.width))
        if let mask { l.mask.kind = .image; l.mask.maskFile = mask }
        // Right above the photo stack (below text/shape layers)
        s.layers.insert(l, at: min(aiLayerCut, s.layers.count))
        replaceSettings(s, recordUndo: true, label: name)
        layersTab.select(l.id)
        if mode == .studio { retouchEditor.reload() }
    }

    /// Runs engine work in the background (shown in the jobs panel), alerts on failure
    func runAI(_ title: String, _ work: @escaping () throws -> Void) {
        JobCenter.shared.begin("ai-\(title)", title: title)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { JobCenter.shared.end("ai-\(title)") }
            do { try BackgroundGate.during { try work() } } catch {
                if ProcessInfo.processInfo.environment["DUOCHROME_FIELDTEST"] != nil {
                    print("AI 시험 실패: \(title): \(error.localizedDescription)")
                    ColabEngine.shared.stop("시험 실패")
                    AIEngine.shared.stop()
                    // Revert layers the test added (left behind, the next test ran with heavy layers)
                    DispatchQueue.main.sync { MainWindowController.fieldTestAbort?() }
                    exit(1)
                }
                DispatchQueue.main.async {
                    let a = NSAlert(); a.messageText = "\(title) 실패"; a.informativeText = error.localizedDescription; a.runModal()
                }
            }
        }
    }

    // MARK: Remove (erase painted area) · Smart erase

    /// Erases the area painted with source-coordinate strokes. With smart, expands to similar-colored surroundings
    /// Fast: compute only the painted bounds; rendering, saving, and engine work all happen in the background (main thread only plans)
    func aiRemove(strokes: [MaskStroke], smart: Bool) {
        guard let doc = photo, !strokes.isEmpty, let composite = nativeComposite() else { NSSound.beep(); return }
        let n = doc.nativeSize
        let full = CGRect(origin: .zero, size: n)
        let brush = Layers.brushMask(strokes, scale: 1, native: n)
        // Painted box: directly from points and brush size (no rendering to find it)
        guard var box = AIRegion.strokeBounds(strokes)?.intersection(full), !box.isEmpty else { NSSound.beep(); return }
        let grow: CGFloat = smart ? 40 : 0
        box = box.insetBy(dx: -grow, dy: -grow).intersection(full)
        // Generous margin (erase fills by looking at the surroundings)
        let pad = max(64, max(box.width, box.height) * 0.6)
        let r = box.insetBy(dx: -pad, dy: -pad).intersection(full).integral
        let title = smart ? "스마트 지우기" : "지우기"
        runAI(title) { [weak self] in
            let mask = smart ? Self.smartExpand(brush, image: composite, work: r) : brush
            let (img, _) = AIRegion.prepare(composite, region: r, limit: 1536)
            let (m, _) = AIRegion.prepare(mask, region: r, limit: 1536)
            guard let imgPNG = AIRegion.png(img), let maskPNG = AIRegion.png(m, gray: true) else { throw AIEngine.Failure(message: "그림을 만들지 못함") }
            // Layer mask: painted area slightly grown and feathered, saved at quarter size (upscaled to source size on load)
            let soft = mask.cropped(to: r).clampedToExtent().applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 6]).blurred(4).cropped(to: r)
            let maskFile = AIRegion.storeMask(soft, native: n)
            let e = AIEngine.shared
            try e.ensureRunning()
            let a = try e.upload(imgPNG, name: "duochrome-in.png"), b = try e.upload(maskPNG, name: "duochrome-mask.png")
            guard let out = try e.run(AIWorkflows.remove(image: a, mask: b), title: title).first, let res = CIImage(data: out) else { throw AIEngine.Failure(message: "결과 그림이 없음") }
            DispatchQueue.main.async { self?.placeAIResult(res, region: r, name: title, mask: maskFile) }
        }
    }

    /// Smart erase: pixels similar to the painted area's mean color within 40 px around it. Computed only inside the work box
    static func smartExpand(_ mask: CIImage, image: CIImage, work: CGRect) -> CIImage {
        let e = work
        let m = mask.cropped(to: e)
        let ring = m.clampedToExtent().applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 40]).cropped(to: e)
        // Mean color of the painted area (weighted: mean of mask product / mask mean). Measured at 512 on the long side
        let k = min(1, 512 / max(e.width, e.height))
        func avg(_ i: CIImage) -> [Float] {
            var p = [Float](repeating: 0, count: 4)
            let small = i.cropped(to: e).transformed(by: .init(scaleX: k, y: k))
            Render.context.render(small.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: small.extent)]), toBitmap: &p, rowBytes: 16,
                                  bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            return p
        }
        let mAvg = avg(m)[0]
        let prod = avg(image.cropped(to: e).applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: m]))
        guard mAvg > 1e-6, let kernel = similarKernel else { return mask }
        let c = CIVector(x: CGFloat(prod[0] / mAvg), y: CGFloat(prod[1] / mAvg), z: CGFloat(prod[2] / mAvg))
        let sim = kernel.apply(extent: e, arguments: [image.cropped(to: e), c]) ?? m
        let near = sim.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: ring]).cropped(to: e)
        return near.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: m]).cropped(to: e)
            .composited(over: mask)
    }

    static let similarKernel = CIColorKernel(source: """
    kernel vec4 similar(__sample s, vec3 c) {
        float d = length(s.rgb - c) / (length(c) + 0.05);
        float w = 1.0 - smoothstep(0.12, 0.25, d);
        return vec4(w, w, w, 1.0);
    }
    """)

    // MARK: Generative fill

    /// Fills inside the selected layer's mask (selection) according to the text prompt
    func aiGenerativeFill(prompt: String) {
        guard let doc = photo, let id = layersTab.selectedID, let l = doc.settings.layers.first(where: { $0.id == id }), l.mask.kind != .full || l.mask.vector != nil,
              let composite = nativeComposite() else {
            let a = NSAlert(); a.messageText = "채울 곳을 먼저 선택하세요"; a.informativeText = "선택 도구로 영역을 만든 뒤(선택 레이어를 고른 상태) 다시 누르세요."; a.runModal(); return
        }
        let n = doc.nativeSize
        let full = CGRect(origin: .zero, size: n)
        let mask = Layers.maskImage(l.mask, scale: 1, native: n, shape: { i, _ in i }, base: CIImage(color: .gray).cropped(to: full)).cropped(to: full)
        guard let box = AIRegion.bounds(of: mask) else { NSSound.beep(); return }
        // Grow the box by half so it continues from the surroundings. At the size the model draws best (1024 long side)
        let pad = max(96, max(box.width, box.height) * 0.5)
        let r = box.insetBy(dx: -pad, dy: -pad).intersection(full).integral
        let seed = Int.random(in: 0..<Int(Int32.max))
        let limit: CGFloat = AIRemote.current == .local ? 1024 : 1344
        runAI("생성형 채우기") { [weak self] in
            let (img, _) = AIRegion.prepare(composite, region: r, limit: limit)
            let (m, _) = AIRegion.prepare(mask, region: r, limit: limit)
            let maskFile = AIRegion.storeMask(mask.cropped(to: r).clampedToExtent().blurred(6).cropped(to: r), native: n)
            guard let imgPNG = AIRegion.png(img), let maskPNG = AIRegion.png(m, gray: true) else { throw AIEngine.Failure(message: "그림을 만들지 못함") }
            let out = try Self.heavyAI("생성형 채우기", inputs: [("in.png", imgPNG), ("mask.png", maskPNG)],
                                       remote: { AIWorkflows.fluxFill(image: "in.png", mask: "mask.png", prompt: prompt, seed: seed, fp8: $0) },
                                       local: { AIWorkflows.fill(image: $0[0], mask: $0[1], prompt: prompt, seed: seed) })
            guard let res = CIImage(data: out) else { throw AIEngine.Failure(message: "결과 그림이 없음") }
            DispatchQueue.main.async { self?.placeAIResult(res, region: r, name: "생성형 채우기", mask: maskFile) }
        }
    }

    @objc func generativeFillFromMenu(_ sender: Any?) {
        startAIEngine()   // Start when the tool is picked (warm up while the prompt is typed)
        let a = NSAlert()
        a.messageText = "생성형 채우기"
        a.informativeText = "선택한 곳을 무엇으로 채울지 적으세요 (영어가 더 잘 듣습니다). 비워 두면 둘레에 맞춰 자연스럽게 채웁니다."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        f.placeholderString = "예: concrete wall with moss"
        a.accessoryView = f
        a.addButton(withTitle: "채우기"); a.addButton(withTitle: "취소").keyEquivalent = "\u{1b}"
        guard a.runModal() == .alertFirstButtonReturn else { return }
        aiGenerativeFill(prompt: f.stringValue)
    }

    // MARK: Generative expand (as a new photo)

    /// Extends all sides into a new photo: generates only the extension, keeps the center original. Saved and opened as TIFF
    func aiGenerativeExpand(percent: Double, prompt: String) {
        guard let doc = photo else { NSSound.beep(); return }
        let img = doc.withFullResolution { doc.image(scale: 1) }
        let e = img.extent
        let dx = (e.width * percent / 100 / 2).rounded(), dy = (e.height * percent / 100 / 2).rounded()
        let big = CGRect(x: 0, y: 0, width: e.width + dx * 2, height: e.height + dy * 2)
        let placed = img.transformed(by: .init(translationX: dx - e.minX, y: dy - e.minY))
        let canvas = placed.composited(over: CIImage(color: .gray).cropped(to: big))
        // Extension = white (overlaps inward a little to hide the seam)
        let inner = CGRect(x: dx + 12, y: dy + 12, width: e.width - 24, height: e.height - 24)
        let mask = CIImage(color: .black).cropped(to: inner).composited(over: CIImage(color: .white).cropped(to: big))
        let limit: CGFloat = AIRemote.current == .local ? 1024 : 1344
        let (small, _) = AIRegion.prepare(canvas, region: big, limit: limit)
        let (m, _) = AIRegion.prepare(mask, region: big, limit: limit)
        guard let imgPNG = AIRegion.png(small), let maskPNG = AIRegion.png(m, gray: true) else { return }
        let seed = Int.random(in: 0..<Int(Int32.max))
        let base = doc.url.deletingPathExtension().lastPathComponent
        let folder = URL(fileURLWithPath: ExportRecipe().folder)
        runAI("생성형 확장") { [weak self] in
            let out = try Self.heavyAI("생성형 확장", inputs: [("in.png", imgPNG), ("mask.png", maskPNG)],
                                       remote: { AIWorkflows.fluxFill(image: "in.png", mask: "mask.png", prompt: prompt, seed: seed, fp8: $0) },
                                       local: { AIWorkflows.fill(image: $0[0], mask: $0[1], prompt: prompt, seed: seed) })
            guard let res = CIImage(data: out) else { throw AIEngine.Failure(message: "결과 그림이 없음") }
            // Scale the generated border back to full size and keep original pixels in the center (blended)
            let up = res.transformed(by: .init(scaleX: big.width / res.extent.width, y: big.height / res.extent.height)).cropped(to: big)
            let blend = CIImage(color: .white).cropped(to: inner).composited(over: CIImage(color: .black).cropped(to: big)).blurred(10).cropped(to: big)
            let final = placed.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: up, kCIInputMaskImageKey: blend]).cropped(to: big)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("\(base)_확장\(Int(percent)).tif")
            guard let cg = Render.exportContext.createCGImage(final, from: big, format: .RGBA16, colorSpace: AIRegion.srgb),
                  let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil) else { throw AIEngine.Failure(message: "파일을 쓰지 못함") }
            CGImageDestinationAddImage(dest, cg, nil)
            guard CGImageDestinationFinalize(dest) else { throw AIEngine.Failure(message: "파일을 쓰지 못함") }
            DispatchQueue.main.async { self?.openFileOrFolder(url) }
        }
    }

    @objc func generativeExpandFromMenu(_ sender: Any?) {
        startAIEngine()
        let a = NSAlert()
        a.messageText = "생성형 확장"
        a.informativeText = "사방을 늘려 새 사진(TIFF, 내보내기 폴더)을 만듭니다. 늘린 곳만 새로 그리고 가운데는 원본 그대로입니다."
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 30, width: 320, height: 26))
        pop.addItems(withTitles: ["10% 늘리기", "20% 늘리기", "35% 늘리기", "50% 늘리기"])
        pop.selectItem(at: 1)
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        f.placeholderString = "설명 (비우면 둘레에 맞춰)"
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 58)); v.addSubview(pop); v.addSubview(f)
        a.accessoryView = v
        a.addButton(withTitle: "만들기"); a.addButton(withTitle: "취소").keyEquivalent = "\u{1b}"
        guard a.runModal() == .alertFirstButtonReturn else { return }
        aiGenerativeExpand(percent: [10.0, 20, 35, 50][pop.indexOfSelectedItem], prompt: f.stringValue)
    }

    // MARK: Denoise · 2× upscale

    /// AI denoise: sends the full-size composite to the engine for tiled processing, result as a full-photo layer
    @objc func aiDenoise(_ sender: Any?) {
        guard let doc = photo, let composite = nativeComposite() else { NSSound.beep(); return }
        let n = doc.nativeSize
        let r = CGRect(origin: .zero, size: n)
        let remote = AIRemote.current != .local
        runAI("AI 노이즈 제거") { [weak self] in
            // Whole source, so Colab round-trips as a very high quality JPEG (~1/5 of PNG, no visible difference)
            guard let input = remote ? AIRegion.jpeg(composite.cropped(to: r)) : AIRegion.png(composite.cropped(to: r)) else { throw AIEngine.Failure(message: "그림을 만들지 못함") }
            let name = remote ? "in.jpg" : "in.png"
            let out = try Self.heavyAI("AI 노이즈 제거", inputs: [(name, input)], jpeg: true,
                                       remote: { _ in AIWorkflows.imageModel(image: name, model: "scunet_color_real_psnr.pth") },
                                       local: { AIWorkflows.imageModel(image: $0[0], model: "scunet_color_real_psnr.pth") })
            guard let res = CIImage(data: out) else { throw AIEngine.Failure(message: "결과 그림이 없음") }
            DispatchQueue.main.async { self?.placeAIResult(res, region: r, name: "AI 노이즈 제거", mask: nil) }
        }
    }

    /// 2× upscale: writes a TIFF of the current look (source size) doubled, into the export folder
    @objc func aiUpscale2x(_ sender: Any?) {
        guard let doc = photo else { NSSound.beep(); return }
        let img = doc.withFullResolution { doc.image(scale: 1) }
        let e = img.extent
        let flat = img.transformed(by: .init(translationX: -e.minX, y: -e.minY)).cropped(to: CGRect(origin: .zero, size: e.size))
        let base = doc.url.deletingPathExtension().lastPathComponent
        let folder = URL(fileURLWithPath: ExportRecipe().folder)
        let remote = AIRemote.current != .local
        runAI("2배 확대") {
            guard let input = remote ? AIRegion.jpeg(flat) : AIRegion.png(flat) else { throw AIEngine.Failure(message: "그림을 만들지 못함") }
            let name = remote ? "in.jpg" : "in.png"
            let out = try Self.heavyAI("2배 확대", inputs: [(name, input)], jpeg: remote,
                                       remote: { _ in AIWorkflows.imageModel(image: name, model: "RealESRGAN_x2plus.pth") },
                                       local: { AIWorkflows.imageModel(image: $0[0], model: "RealESRGAN_x2plus.pth") })
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let isPNG = out.starts(with: [0x89, 0x50, 0x4E, 0x47])
            let url = folder.appendingPathComponent("\(base)_2배.\(isPNG ? "png" : "jpg")")
            try out.write(to: url)
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    // MARK: Reflection removal (glass)

    /// Creates a full-photo layer with window reflections removed. Reflections are broad luminance, so subtract on a downscaled image
    /// and add only the difference upscaled to full size (fine source texture intact). Colab long side 1536, this Mac 1024
    @objc func aiRemoveReflection(_ sender: Any?) {
        guard let doc = photo, let composite = nativeComposite() else { NSSound.beep(); return }
        startAIEngine()
        let n = doc.nativeSize
        let r = CGRect(origin: .zero, size: n)
        let limit: CGFloat = AIRemote.current == .local ? 1024 : 1536
        runAI("반사 제거") { [weak self] in
            let (small, _) = AIRegion.prepare(composite, region: r, limit: limit)
            guard let png = AIRegion.png(small), let sent = CIImage(data: png) else { throw AIEngine.Failure(message: "그림을 만들지 못함") }
            let out = try Self.heavyAI("반사 제거", inputs: [("in.png", png)],
                                       remote: { _ in AIWorkflows.reflection(image: "in.png") },
                                       local: { AIWorkflows.reflection(image: $0[0]) })
            guard let res = CIImage(data: out), let k = Self.addDiffKernel else { throw AIEngine.Failure(message: "결과 그림이 없음") }
            func up(_ i: CIImage) -> CIImage {
                let e = i.extent
                return i.transformed(by: .init(translationX: -e.minX, y: -e.minY))
                    .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: n.height / e.height, kCIInputAspectRatioKey: (n.width / e.width) / (n.height / e.height)])
                    .clampedToExtent().cropped(to: r)
            }
            // The sent image is read back and subtracted too, so 8-bit and color-space round-trip errors cancel out
            guard let final = k.apply(extent: r, arguments: [composite.cropped(to: r), up(res), up(sent)]) else { throw AIEngine.Failure(message: "합치지 못함") }
            DispatchQueue.main.async { self?.placeAIResult(final, region: r, name: "반사 제거", mask: nil) }
        }
    }

    static let addDiffKernel = CIColorKernel(source: """
    kernel vec4 addDiff(__sample a, __sample b, __sample c) { return vec4(a.rgb + b.rgb - c.rgb, a.a); }
    """)

    @objc func stopColab(_ sender: Any?) {
        runAI("코랩 끄기") { ColabEngine.shared.stop("메뉴로 끔") }
    }

    @objc func reinstallAIEngine(_ sender: Any?) {
        runAI("AI 엔진 설치") { try AIEngine.shared.install() }
    }
}
