import AppKit
import CoreImage
import Vision

// MARK: - AI stage 1: built-in macOS AI (no downloads) — background removal, crop suggestions, sky selection, skin mask, object selection

enum AIBasic {
    /// Quarter-size image in source coordinates and its CGImage (for analysis)
    static func nativeSmall(_ doc: RawDocument, scale: CGFloat = 0.25) -> (CIImage, CGImage)? {
        let img = doc.nativePreview(scale: scale)
        let e = img.extent
        guard let cg = Render.context.createCGImage(img, from: e, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        return (img, cg)
    }

    /// Saves a grayscale mask into the layer image folder (sized to cover the whole source)
    static func store(_ m: CIImage, size: CGSize) -> String? {
        let r = CGRect(origin: .zero, size: size)
        let me = m.extent
        let fitted = m.transformed(by: .init(scaleX: size.width / max(me.width, 1), y: size.height / max(me.height, 1)))
            .transformed(by: .init(translationX: -me.minX * size.width / max(me.width, 1), y: -me.minY * size.height / max(me.height, 1)))
        guard let png = Render.context.pngRepresentation(of: fitted.cropped(to: r), format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) else { return nil }
        return try? LayerImageStore.importData(png, ext: "png")
    }

    // MARK: Sky selection
    /// macOS AI has no sky segmentation, so build it from image cues:
    /// skyness = brightness · blueness · low texture (clouds and clear sky alike), more toward the top, and not warm-tinted
    /// (bright beige walls are as smooth and bright as clouds, but sky and clouds are neutral to cool). Keep only regions connected
    /// to the top edge without crossing a color edge, fill small holes (cloud texture), then refine edges with image luminance.
    static func skyMask(_ doc: RawDocument) -> String? {
        guard let (img, cg) = nativeSmall(doc, scale: 0.125) else { return nil }
        let w = cg.width, h = cg.height
        guard w > 8, h > 8 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // px row 0 is the top (CGContext memory order)
        func lum(_ i: Int) -> Float { (0.299 * Float(px[i * 4]) + 0.587 * Float(px[i * 4 + 1]) + 0.114 * Float(px[i * 4 + 2])) / 255 }
        var L = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { L[i] = lum(i) }
        // Texture: mean luminance difference over the 3×3 neighborhood
        var tex = [Float](repeating: 0, count: w * h)
        for y in 1..<(h - 1) { for x in 1..<(w - 1) {
            let c = L[y * w + x]
            var d: Float = 0
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] { d += abs(L[(y + dy) * w + x + dx] - c) }
            tex[y * w + x] = d / 4
        } }
        // Warmth (red minus blue): sky and clouds are neutral or cool, sunlit concrete and sand are warm
        var warm = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { warm[i] = (Float(px[i * 4]) - Float(px[i * 4 + 2])) / 255 }
        func region(coolOnly: Bool) -> [Int] {
            // Skyness score
            var score = [Float](repeating: 0, count: w * h)
            for y in 0..<h { for x in 0..<w {
                let i = y * w + x
                let r = Float(px[i * 4]) / 255, g = Float(px[i * 4 + 1]) / 255, b = Float(px[i * 4 + 2]) / 255
                let blue = max(0, b - max(r, g * 0.9))            // blue sky
                let white = L[i] > 0.72 ? (L[i] - 0.72) * 3 : 0   // white overcast sky
                let smooth = max(0, 1 - tex[i] * 18)              // less texture scores higher
                let top = 1 - Float(y) / Float(h) * 0.9           // higher up scores higher
                let cool = coolOnly ? max(0, min(1, 1 - (warm[i] - 0.015) * 25)) : 1   // fades out from r − b ≈ 0.015 to 0.055
                score[i] = min(1, (blue * 4 + white + 0.15) * smooth * top * cool * 1.6)
            } }
            // Only sky-like regions connected to the top edge (flood fill), not crossing a luminance or color edge
            var seen = [Bool](repeating: false, count: w * h)
            var queue: [Int] = []
            for x in 0..<w where score[x] > 0.35 { queue.append(x); seen[x] = true }
            var head = 0
            while head < queue.count {
                let i = queue[head]; head += 1
                let x = i % w, y = i / w
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    let j = ny * w + nx
                    if !seen[j], score[j] > 0.3, abs(L[j] - L[i]) < 0.12, !coolOnly || abs(warm[j] - warm[i]) < 0.03 {
                        seen[j] = true; queue.append(j)
                    }
                }
            }
            return queue
        }
        // Warm skies (sunsets) fail the cool test: fall back to the brightness/texture rule when it finds almost nothing
        var queue = region(coolOnly: true)
        if queue.count <= w * h / 200 { queue = region(coolOnly: false) }
        guard queue.count > w * h / 200 else { return nil }   // almost no sky
        var out = [UInt8](repeating: 0, count: w * h)
        for i in queue { out[i] = 255 }
        // Fill small holes inside the sky (cloud texture, birds): unselected areas not reachable from the image border
        // and smaller than 0.5% of the image
        var outside = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        for x in 0..<w { stack.append(x); stack.append((h - 1) * w + x) }
        for y in 0..<h { stack.append(y * w); stack.append(y * w + w - 1) }
        stack = stack.filter { out[$0] == 0 }
        for i in stack { outside[i] = true }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                let j = ny * w + nx
                if out[j] == 0, !outside[j] { outside[j] = true; stack.append(j) }
            }
        }
        var visited = [Bool](repeating: false, count: w * h)
        for start in 0..<(w * h) where out[start] == 0 && !outside[start] && !visited[start] {
            var hole = [start]; visited[start] = true
            var k = 0
            while k < hole.count {
                let i = hole[k]; k += 1
                let x = i % w, y = i / w
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    let j = ny * w + nx
                    if out[j] == 0, !visited[j] { visited[j] = true; hole.append(j) }
                }
            }
            if hole.count < w * h / 200 { for i in hole { out[i] = 255 } }
        }
        // CGImage (row 0 at top) → CIImage
        guard let prov = CGDataProvider(data: Data(out) as CFData),
              let mcg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        var m = CIImage(cgImage: mcg).clampedToExtent().blurred(1.2).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        // Refine edges guided by image luminance (between branches and wires)
        let guide = img.transformed(by: .init(scaleX: CGFloat(w) / img.extent.width, y: CGFloat(h) / img.extent.height))
        let coarse = m
        m = Layers.refineMask(m, guide: guide.cropped(to: m.extent), radius: 3)
        // Refining left specks inside bright clouds: well inside the coarse sky (shrunk by 2 px) stays fully selected
        let core = coarse.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 2]).cropped(to: m.extent)
        m = core.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: m]).cropped(to: m.extent)
        return store(m, size: doc.nativeSize)
    }

    // MARK: Skin mask
    /// Person region ∩ skin tones (YCbCr range). Skin only: face, arms, etc.
    static func skinMask(_ doc: RawDocument) -> String? {
        guard let (img, cg) = nativeSmall(doc) else { return nil }
        let handler = VNImageRequestHandler(cgImage: cg)
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .accurate
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        guard (try? handler.perform([req])) != nil, let buf = req.results?.first?.pixelBuffer else { return nil }
        var person = CIImage(cvPixelBuffer: buf)
        let e = img.extent
        person = person.transformed(by: .init(scaleX: e.width / person.extent.width, y: e.height / person.extent.height))
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let k = skinColorKernel, let s = img.matchedFromWorkingSpace(to: srgb),
              let skin = k.apply(extent: e, arguments: [s.applyingFilter("CIColorClamp")]) else { return nil }
        let m = skin.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: person]).cropped(to: e)
            .clampedToExtent().blurred(2).cropped(to: e)
        return store(m, size: doc.nativeSize)
    }

    private static let skinColorKernel = CIColorKernel(source: """
    kernel vec4 skin(__sample s) {
        vec3 c = s.rgb;
        float cb = 0.5 - 0.168736 * c.r - 0.331264 * c.g + 0.5 * c.b;
        float cr = 0.5 + 0.5 * c.r - 0.418688 * c.g - 0.081312 * c.b;
        float a = smoothstep(0.28, 0.32, cb) * (1.0 - smoothstep(0.50, 0.54, cb));
        float b = smoothstep(0.51, 0.55, cr) * (1.0 - smoothstep(0.68, 0.72, cr));
        float v = a * b;
        return vec4(v, v, v, 1.0);
    }
    """)

    // MARK: Object selection (things inside a rectangle)
    /// Only the macOS foreground instances that lie mostly inside the rectangle (source-coordinate rect)
    static func objectMask(_ doc: RawDocument, rect: CGRect) -> String? {
        guard let (img, cg) = nativeSmall(doc) else { return nil }
        let e = img.extent
        let k = e.width / doc.nativeSize.width
        let r = CGRect(x: rect.minX * k, y: rect.minY * k, width: rect.width * k, height: rect.height * k)
        let handler = VNImageRequestHandler(cgImage: cg)
        let req = VNGenerateForegroundInstanceMaskRequest()
        guard (try? handler.perform([req])) != nil, let obs = req.results?.first else { return nil }
        var chosen = IndexSet()
        for inst in obs.allInstances {
            guard let b = try? obs.generateScaledMaskForImage(forInstances: IndexSet(integer: inst), from: handler) else { continue }
            let m = CIImage(cvPixelBuffer: b)
            let mm = m.transformed(by: .init(scaleX: e.width / m.extent.width, y: e.height / m.extent.height))
            func area(_ in_: CGRect) -> Float {
                var p = [Float](repeating: 0, count: 4)
                let avg = mm.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: in_)])
                Render.context.render(avg, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                return p[0] * Float(in_.width * in_.height)
            }
            let inside = area(r.intersection(e)), total = area(e)
            if total > 0, inside / total > 0.6 { chosen.insert(inst) }
        }
        var mask: CIImage
        if !chosen.isEmpty, let b = try? obs.generateScaledMaskForImage(forInstances: chosen, from: handler) {
            let m = CIImage(cvPixelBuffer: b)
            mask = m.transformed(by: .init(scaleX: e.width / m.extent.width, y: e.height / m.extent.height))
        } else {
            // If no object is found: the salient area inside the rectangle (saliency map)
            guard let sub = cg.cropping(to: CGRect(x: r.minX, y: e.height - r.maxY, width: r.width, height: r.height)) else { return nil }
            let h2 = VNImageRequestHandler(cgImage: sub)
            let sal = VNGenerateObjectnessBasedSaliencyImageRequest()
            guard (try? h2.perform([sal])) != nil, let sb = sal.results?.first?.pixelBuffer else { return nil }
            let sm = CIImage(cvPixelBuffer: sb)
            mask = sm.transformed(by: .init(scaleX: r.width / sm.extent.width, y: r.height / sm.extent.height))
                .transformed(by: .init(translationX: r.minX, y: r.minY))
                .composited(over: CIImage(color: .black).cropped(to: e))
        }
        // Clear everything outside the rectangle
        let box = CIImage(color: .white).cropped(to: r).composited(over: CIImage(color: .black).cropped(to: e))
        mask = mask.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: box]).cropped(to: e)
        mask = Layers.refineMask(mask, guide: img, radius: 3)
        return store(mask, size: doc.nativeSize)
    }

    // MARK: Crop suggestions
    struct CropIdea { var rect: CGRect; var ratio: String; var score: Float; var angle: Float }

    /// Three crop candidates from saliency, horizon, and aesthetics score (frame coordinates 0–1)
    static func cropIdeas(_ doc: RawDocument) -> [CropIdea] {
        let img = doc.withFullResolution { doc.image(scale: 1.0 / 8) }
        let e = img.extent
        guard let cg = Render.context.createCGImage(img, from: e, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return [] }
        let handler = VNImageRequestHandler(cgImage: cg)
        let sal = VNGenerateAttentionBasedSaliencyImageRequest()
        let horizon = VNDetectHorizonRequest()
        try? handler.perform([sal, horizon])
        // Salient bounding box (0–1, bottom is 0)
        let boxes = sal.results?.first?.salientObjects?.map(\.boundingBox) ?? []
        var focus = boxes.reduce(CGRect.null) { $0.union($1) }
        if focus.isNull { focus = CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3) }
        let angle = Float(horizon.results?.first?.angle ?? 0) * 180 / .pi
        let aspect = e.width / e.height
        var ideas: [CropIdea] = []
        for (name, r) in [("원래 비율", aspect), ("4:5", 4.0 / 5), ("1:1", 1), ("16:9", 16.0 / 9), ("3:2", 1.5)] as [(String, CGFloat)] {
            for zoom in [1.0, 0.85, 0.72] as [CGFloat] {
                // Largest box of that aspect × scale
                var w: CGFloat = 1, h: CGFloat = 1
                if r >= aspect { h = aspect / r } else { w = r / aspect }
                w *= zoom; h *= zoom
                guard w >= focus.width * 0.95 || zoom == 1 else { continue }
                // Candidates placing the salient center on rule-of-thirds intersections
                for (tx, ty) in [(0.5, 0.5), (1 / 3.0, 2 / 3.0), (2 / 3.0, 2 / 3.0), (1 / 3.0, 1 / 3.0), (2 / 3.0, 1 / 3.0)] as [(CGFloat, CGFloat)] {
                    var x = focus.midX - w * tx, y = focus.midY - h * ty
                    x = min(max(x, 0), 1 - w); y = min(max(y, 0), 1 - h)
                    let c = CGRect(x: x, y: y, width: w, height: h)
                    // Penalize cutting through the salient area
                    let cover = focus.intersection(c).width * focus.intersection(c).height / max(focus.width * focus.height, 1e-6)
                    ideas.append(CropIdea(rect: c, ratio: name, score: Float(cover), angle: angle))
                }
            }
        }
        // Among well-framed ones, pick by aesthetics score (best one per aspect)
        var best: [String: CropIdea] = [:]
        for var idea in ideas where idea.score > 0.92 {
            let pr = CGRect(x: idea.rect.minX * e.width, y: idea.rect.minY * e.height, width: idea.rect.width * e.width, height: idea.rect.height * e.height).integral
            if #available(macOS 15, *), let sub = cg.cropping(to: CGRect(x: pr.minX, y: e.height - pr.maxY, width: pr.width, height: pr.height)) {
                let req = VNCalculateImageAestheticsScoresRequest()
                if (try? VNImageRequestHandler(cgImage: sub).perform([req])) != nil, let o = req.results?.first {
                    idea.score = o.overallScore
                }
            }
            if best[idea.ratio].map({ idea.score > $0.score }) ?? true { best[idea.ratio] = idea }
        }
        return best.values.sorted { $0.score > $1.score }.prefix(3).map { $0 }
    }
}

extension MainWindowController {
    // MARK: Menu actions

    /// Computes the AI mask in the background and makes an adjustment layer
    func addAIMaskLayer(_ name: String, compute: @escaping (RawDocument) -> String?, configure: ((inout AdjustLayer) -> Void)? = nil) {
        guard let doc = photo else { NSSound.beep(); return }
        JobCenter.shared.begin("ai-mask", title: name)
        let full = doc
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let file = compute(full)
            DispatchQueue.main.async {
                JobCenter.shared.end("ai-mask")
                guard let self, self.photo === full else { return }
                guard let file else { let a = NSAlert(); a.messageText = "\(name): 찾지 못했습니다"; a.runModal(); return }
                self.layersTab.addLayer(.full, native: full.nativeSize)
                guard var s = self.photo?.settings, let i = s.layers.indices.last else { return }
                s.layers[i].mask.kind = .image
                s.layers[i].mask.maskFile = file
                s.layers[i].name = "\(name) \(s.layers.count)"
                configure?(&s.layers[i])
                self.replaceSettings(s, recordUndo: true, label: name)
                self.layersTab.sync(s)
                if self.mode == .studio { self.retouchEditor.reload() }
            }
        }
    }

    @objc func selectSkyAI(_ sender: Any?) { addAIMaskLayer("하늘 선택") { AIBasic.skyMask($0) } }

    @objc func skinSmoothAI(_ sender: Any?) {
        addAIMaskLayer("피부 매끈하게", compute: { AIBasic.skinMask($0) }) { $0.adjust.skinSmooth = 45 }
    }

    @objc func skinMaskAI(_ sender: Any?) { addAIMaskLayer("스킨 선택") { AIBasic.skinMask($0) } }

    /// Object selection inside a rectangle (source coordinates)
    func selectObject(in rect: CGRect) {
        guard rect.width > 4, rect.height > 4 else { NSSound.beep(); return }
        addAIMaskLayer("개체 선택") { AIBasic.objectMask($0, rect: rect) }
    }

    /// Background removal: make everything outside the subject transparent (calling again undoes it)
    @objc func removeBackgroundAI(_ sender: Any?) {
        guard let doc = photo else { NSSound.beep(); return }
        if doc.settings.cutout != nil {
            var s = doc.settings; s.cutout = nil
            replaceSettings(s, recordUndo: true, label: "배경 되살리기")
            return
        }
        JobCenter.shared.begin("ai-cut", title: "배경 제거")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let file = AISelect.mask(doc, target: .subject)
            DispatchQueue.main.async {
                JobCenter.shared.end("ai-cut")
                guard let self, self.photo === doc, let file, var s = self.photo?.settings else {
                    if file == nil { let a = NSAlert(); a.messageText = "피사체를 찾지 못했습니다"; a.runModal() }
                    return
                }
                s.cutout = file
                self.replaceSettings(s, recordUndo: true, label: "배경 제거")
            }
        }
    }

    /// Crop suggestions: show three candidates and crop to the chosen one (straightening too if tilted)
    @objc func suggestCropAI(_ sender: Any?) {
        guard let doc = photo else { NSSound.beep(); return }
        JobCenter.shared.begin("ai-crop", title: "크롭 제안")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ideas = AIBasic.cropIdeas(doc)
            DispatchQueue.main.async {
                JobCenter.shared.end("ai-crop")
                guard let self, self.photo === doc else { return }
                guard !ideas.isEmpty else { let a = NSAlert(); a.messageText = "크롭 후보를 찾지 못했습니다"; a.runModal(); return }
                self.showCropIdeas(ideas)
            }
        }
    }

    func showCropIdeas(_ ideas: [AIBasic.CropIdea]) {
        guard let doc = photo else { return }
        let a = NSAlert()
        a.messageText = "크롭 제안"
        a.informativeText = "눈길이 가는 곳과 사진 좋음 점수로 고른 후보입니다." + (abs(ideas[0].angle) > 0.3 ? String(format: " 수평이 %.1f° 기울어 있어 함께 바로잡습니다.", ideas[0].angle) : "")
        let img = doc.image(scale: 1.0 / 8)
        let stack = NSStackView()
        stack.spacing = 10
        var buttons: [NSButton] = []
        for (i, idea) in ideas.enumerated() {
            let e = img.extent
            let r = CGRect(x: e.minX + idea.rect.minX * e.width, y: e.minY + idea.rect.minY * e.height, width: idea.rect.width * e.width, height: idea.rect.height * e.height)
            let k = 140 / max(r.width, r.height)
            let small = img.cropped(to: r).transformed(by: .init(scaleX: k, y: k))
            let thumb = Render.context.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: Render.displaySpace)
                .map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            let b = NSButton(title: "\(i + 1). \(idea.ratio)", image: thumb ?? NSImage(), target: nil, action: nil)
            b.imagePosition = .imageAbove
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .regularSquare
            b.tag = i
            b.state = i == 0 ? .on : .off
            buttons.append(b)
            stack.addArrangedSubview(b)
        }
        let picker = RadioGroup(buttons)
        stack.frame = NSRect(x: 0, y: 0, width: CGFloat(ideas.count) * 160, height: 170)
        a.accessoryView = stack
        a.addButton(withTitle: "크롭"); a.addButton(withTitle: "취소")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let idea = ideas[picker.selected]
        var s = doc.settings
        if abs(idea.angle) > 0.3 { s.rotation = min(max(s.rotation - idea.angle, -45), 45) }
        // Ratio within the current frame (already cropped) → relative to the full frame
        let cur = s.crop.cg
        s.crop = CropRect(CGRect(x: cur.minX + idea.rect.minX * cur.width, y: cur.minY + idea.rect.minY * cur.height,
                                 width: idea.rect.width * cur.width, height: idea.rect.height * cur.height))
        replaceSettings(s, recordUndo: true, label: "크롭 제안")
        canvas.zoomToFit()
    }
}

/// Radio behavior across several push buttons
final class RadioGroup: NSObject {
    private let buttons: [NSButton]
    private(set) var selected = 0
    init(_ b: [NSButton]) {
        buttons = b
        super.init()
        for x in b { x.target = self; x.action = #selector(tap(_:)) }
    }
    @objc private func tap(_ b: NSButton) {
        selected = b.tag
        for x in buttons { x.state = x.tag == b.tag ? .on : .off }
    }
}
