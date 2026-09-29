import AppKit
import CoreImage
import ImageIO

// MARK: - Merge commands (Photo → Merge)

extension MainWindowController {
    enum MergeKind { case hdr, panorama(Merge.Projection), focus, median, mean }

    @objc func mergeHDR(_ sender: Any?) { runMerge(.hdr) }
    @objc func mergeFocus(_ sender: Any?) { runMerge(.focus) }
    @objc func mergeMedian(_ sender: Any?) { runMerge(.median) }
    @objc func mergeMean(_ sender: Any?) { runMerge(.mean) }
    @objc func mergePanorama(_ sender: Any?) {
        let a = NSAlert()
        a.messageText = "파노라마"
        a.informativeText = "건물 한 면처럼 좁은 범위는 직선, 넓게 돌려 찍은 것은 원통이나 구면이 좋습니다."
        let pop = NSPopUpButton(); pop.addItems(withTitles: Merge.Projection.allCases.map(\.title)); pop.selectItem(at: 1)
        let half = NSButton(checkboxWithTitle: "절반 크기로 (빠르게)", target: nil, action: nil)
        let st = NSStackView(views: [pop, half]); st.orientation = .vertical; st.alignment = .leading
        st.frame = NSRect(x: 0, y: 0, width: 240, height: 56)
        a.accessoryView = st
        a.addButton(withTitle: "합치기"); a.addButton(withTitle: "취소")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        runMerge(.panorama(Merge.Projection(rawValue: pop.indexOfSelectedItem) ?? .cylindrical), scale: half.state == .on ? 0.5 : 1)
    }

    func runMerge(_ kind: MergeKind, scale: CGFloat = 1) {
        let items = (mode == .library ? libraryMode.grid.selectedItems : browser.selectedItems).filter { !$0.offline }
        guard items.count >= 2 else {
            let a = NSAlert(); a.messageText = "두 장 이상 고르세요"; a.informativeText = "라이브러리 격자나 필름스트립에서 ⌘·⇧로 여러 장을 고릅니다."; a.runModal(); return
        }
        let urls = items.map { URL(fileURLWithPath: $0.url.path) }
        let suffix: String
        switch kind {
        case .hdr: suffix = "HDR"
        case .panorama: suffix = "파노라마"
        case .focus: suffix = "초점스택"
        case .median: suffix = "중앙값"
        case .mean: suffix = "평균"
        }
        let out = Merge.outputURL(urls[0], suffix: suffix)
        window?.subtitle = "\(suffix) 합치는 중… (\(items.count)장)"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let frames = try urls.map { try Merge.load($0, scale: scale) }
                let mid = frames.count / 2
                var result: CIImage?
                switch kind {
                case .hdr:
                    // Align to the middle exposure and merge
                    let order = frames.indices.sorted { frames[$0].exposure < frames[$1].exposure }
                    let ref = order[order.count / 2]
                    let aligned = Merge.alignAll(frames, reference: ref, exposureAware: true)
                    result = Merge.hdr(aligned, exposures: frames.map(\.exposure), reference: ref)
                case .panorama(let p):
                    result = Merge.autoCrop(try Merge.panorama(frames, projection: p, scale: scale))
                case .focus:
                    result = Merge.focusStack(Merge.alignAll(frames, reference: mid), scale: scale)
                case .median:
                    result = Merge.median(Merge.alignAll(frames, reference: mid))
                case .mean:
                    result = Merge.mean(Merge.alignAll(frames, reference: mid))
                }
                guard let img = result else { throw Merge.Failure(message: "합치기 커널을 만들지 못했습니다") }
                try Merge.writeDNG(img, to: out, camera: frames[0].camera)
                DispatchQueue.main.async { self?.mergeDone(out) }
            } catch {
                DispatchQueue.main.async {
                    self?.window?.subtitle = ""
                    if let w = self?.window { NSAlert(error: error).beginSheetModal(for: w) }
                }
            }
        }
    }

    func mergeDone(_ url: URL) {
        _ = try? library.catalog.addFolder(url.deletingLastPathComponent())
        library.show(library.source)
        reloadAfterLibraryChange()
        window?.subtitle = "합친 결과: \(url.lastPathComponent)"
        if let item = library.items.first(where: { $0.url.path == url.path }) {
            libraryMode.grid.mirror(item); browser.mirror(item)
            if mode != .library { show(item) }
        }
    }

    // MARK: - Auto-align layers · auto-blend layers

    private var imageLayerIDs: [String] {
        (photo?.settings.layers ?? []).filter { $0.isImage && $0.image != nil }.map(\.id)
    }

    /// Aligns image layers to the background (photo): approximates the homography as move/rotate/scale and writes it to the layer position
    @objc func autoAlignLayers(_ sender: Any?) {
        guard let doc = photo, var s = photo?.settings, !imageLayerIDs.isEmpty else { NSSound.beep(); return }
        let n = doc.nativeSize
        guard let bg = rasterize([], withPhoto: true) else { return }
        var moved = 0
        for id in imageLayerIDs {
            guard let i = s.layers.firstIndex(where: { $0.id == id }), var im = s.layers[i].image else { continue }
            var solo = s.layers[i]; solo.mask = LayerMask(); solo.opacity = 1; solo.blend = "normal"; solo.group = nil; solo.clipped = false; solo.enabled = true
            guard let content = rasterize([solo], withPhoto: false),
                  let h = Merge.align(content.composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: n))), to: bg) else { continue }
            // Derive move/rotate/scale from where the layer center and one horizontal point go
            let c = CGPoint(x: im.cx, y: im.cy)
            let rx = CGPoint(x: im.cx + 100, y: im.cy)
            let c2 = Merge.apply(h, c), r2 = Merge.apply(h, rx)
            let k = hypot(r2.x - c2.x, r2.y - c2.y) / 100
            let rot = atan2(r2.y - c2.y, r2.x - c2.x) * 180 / .pi
            im.cx = c2.x; im.cy = c2.y
            im.width *= k
            if let hh = im.height { im.height = hh * k }
            im.rotation += rot
            s.layers[i].image = im
            moved += 1
        }
        replaceSettings(s, recordUndo: true, label: "자동 정렬 레이어")
        window?.subtitle = "자동 정렬: 레이어 \(moved)개"
    }

    /// Auto blend: builds a mask per layer for stacking (sharpest areas) or panorama (edges blended smoothly).
    /// Layers stack upward, so mask = this weight ÷ (all weights below + this weight) yields a weighted average.
    @objc func autoBlendLayers(_ sender: Any?) {
        guard let doc = photo, var s = photo?.settings, !imageLayerIDs.isEmpty else { NSSound.beep(); return }
        let a = NSAlert()
        a.messageText = "자동 혼합 레이어"
        let pop = NSPopUpButton(); pop.addItems(withTitles: ["이미지 쌓기 (가장 선명한 곳)", "파노라마 (이음새를 부드럽게)"])
        a.accessoryView = pop
        a.addButton(withTitle: "혼합"); a.addButton(withTitle: "취소")
        let testMode = ProcessInfo.processInfo.environment["DUOCHROME_UITEST"] != nil
        guard testMode || a.runModal() == .alertFirstButtonReturn else { return }
        let stack = testMode || pop.indexOfSelectedItem == 0
        let n = doc.nativeSize
        let rect = CGRect(origin: .zero, size: n)
        let k: CGFloat = min(1, 3000 / max(n.width, n.height))
        func small(_ i: CIImage) -> CIImage { i.transformed(by: .init(scaleX: k, y: k)) }
        guard let bg = rasterize([], withPhoto: true) else { return }
        var contents: [CIImage] = [small(bg)]
        for id in imageLayerIDs {
            guard let i = s.layers.firstIndex(where: { $0.id == id }) else { continue }
            var solo = s.layers[i]; solo.mask = LayerMask(); solo.opacity = 1; solo.blend = "normal"; solo.group = nil; solo.enabled = true
            contents.append(small(rasterize([solo], withPhoto: false) ?? CIImage(color: .clear).cropped(to: rect)))
        }
        let sr = CGRect(x: 0, y: 0, width: (n.width * k).rounded(), height: (n.height * k).rounded())
        // Weights: stacking uses sharpness^4 × alpha; panorama blurs alpha so it shrinks toward edges
        let weights: [CIImage] = contents.map { c in
            let alpha = LayerStyles.alphaGray(c)
            if stack {
                let sharp = Merge.focusWeights(c, scale: k)
                return sharp.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: alpha]).cropped(to: sr)
            }
            let r = max(sr.width, sr.height) * 0.03
            let soft = alpha.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: r]).clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: r]).cropped(to: sr)
            return soft.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: alpha]).cropped(to: sr)
        }
        var cum = weights[0]
        var made = 0
        for (j, id) in imageLayerIDs.enumerated() {
            let w = weights[j + 1]
            cum = Merge.addK?.apply(extent: sr, arguments: [cum, w]) ?? cum
            guard let ratio = Merge.ratioK?.apply(extent: sr, arguments: [w, cum]),
                  let cg = Render.context.createCGImage(ratio.transformed(by: .init(scaleX: 1 / k, y: 1 / k)).cropped(to: rect), from: rect,
                                                        format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()),
                  let file = PSDImport.writeImage(cg), let i = s.layers.firstIndex(where: { $0.id == id }) else { continue }
            s.layers[i].mask = LayerMask(kind: .image, maskFile: file)
            made += 1
        }
        replaceSettings(s, recordUndo: true, label: stack ? "자동 혼합 (쌓기)" : "자동 혼합 (파노라마)")
        window?.subtitle = "자동 혼합: 마스크 \(made)개"
    }
}

extension Merge {
    /// Weight ratio (mask)
    static let ratioK = CIColorKernel(source: """
        kernel vec4 k(__sample w, __sample c) { float v = c.r > 1e-5 ? clamp(w.r / c.r, 0.0, 1.0) : 0.0; return vec4(v, v, v, 1.0); }
        """)

    /// Sharpness weight map (same as focus stacking)
    static func focusWeights(_ img: CIImage, scale: CGFloat) -> CIImage {
        let g = img.applyingFilter("CILinearToSRGBToneCurve")
        let lap = g.applyingFilter("CIConvolution3X3", parameters: ["inputWeights": CIVector(values: [0, 1, 0, 1, -4, 1, 0, 1, 0], count: 9), "inputBias": 0.5])
        let mag = sharpK?.apply(extent: img.extent, arguments: [lap]) ?? lap
        let blurred = mag.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(6 * scale, 1.5)]).cropped(to: img.extent)
        return powK?.apply(extent: img.extent, arguments: [blurred]) ?? blurred
    }
    static let powK = CIColorKernel(source: "kernel vec4 k(__sample s) { float v = pow(s.r * 20.0, 4.0) + 1e-6; return vec4(v, v, v, 1.0); }")
}

// MARK: - LCC (flat-field correction: color cast, light falloff, dust)

enum LCC {
    struct Profile: Codable, Equatable { var name: String; var file: String; var dust: [Double] }   // dust: x, y, radius (source coordinates) repeated

    static var profiles: [Profile] {
        get { (UserDefaults.standard.data(forKey: "lcc.profiles").flatMap { try? JSONDecoder().decode([Profile].self, from: $0) }) ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "lcc.profiles") }
    }

    /// LCC photo (shot through a white diffuser) → ratio map relative to the center (linear, float TIFF) and dust positions
    static func make(from doc: RawDocument) -> Profile? {
        var s = doc.asShot
        s.filmCurve = 0; s.look = 0
        let saved = doc.settings
        doc.settings = s
        let scale: CGFloat = 1.0 / 8
        let img = doc.nativePreview(scale: scale)
        doc.settings = saved
        let e = img.extent
        let smooth = img.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 12]).cropped(to: e)
        // divide by the center value
        let c = CGRect(x: e.midX - 8, y: e.midY - 8, width: 16, height: 16)
        var px = [Float](repeating: 0, count: 4)
        let avg = smooth.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: c)])
        Render.context.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        guard px[0] > 1e-4, px[1] > 1e-4, px[2] > 1e-4 else { return nil }
        let map = smooth.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(1 / px[0]), y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: CGFloat(1 / px[1]), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(1 / px[2]), w: 0)])
            .transformed(by: .init(translationX: -e.minX, y: -e.minY))
        let r = CGRect(origin: .zero, size: e.size)
        guard let cg = Render.context.createCGImage(map, from: r, format: .RGBAh, colorSpace: Render.workingSpace),
              let file = PSDImport.writeImage(cg, float: true) else { return nil }
        // Dust: small spots more than 3% darker than their surroundings at 1/4 resolution
        let dimg = doc.nativePreview(scale: 0.25)
        var ds = doc.asShot; ds.filmCurve = 0
        let de = dimg.extent
        let lum = dimg.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        let local = lum.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 16]).cropped(to: de)
        let w = Int(de.width), h = Int(de.height)
        var a = [Float](repeating: 0, count: w * h * 4), b = a
        Render.context.render(lum, toBitmap: &a, rowBytes: w * 16, bounds: de, format: .RGBAf, colorSpace: nil)
        Render.context.render(local, toBitmap: &b, rowBytes: w * 16, bounds: de, format: .RGBAf, colorSpace: nil)
        var dust: [Double] = []
        var taken = [Bool](repeating: false, count: w * h)
        for y in stride(from: 4, to: h - 4, by: 1) { for x in stride(from: 4, to: w - 4, by: 1) {
            let i = y * w + x
            guard !taken[i], b[i * 4] > 0.02, a[i * 4] < b[i * 4] * 0.97 else { continue }
            // Small blobs only (broad dark areas are light falloff)
            var cnt = 0, sx = 0, sy = 0
            for yy in max(0, y - 10) ..< min(h, y + 10) { for xx in max(0, x - 10) ..< min(w, x + 10) {
                let j = yy * w + xx
                if a[j * 4] < b[j * 4] * 0.97 { cnt += 1; sx += xx; sy += yy; taken[j] = true }
            } }
            guard cnt >= 2, cnt < 150 else { continue }
            let cx = Double(sx) / Double(cnt), cy = Double(h - 1) - Double(sy) / Double(cnt)
            let rad = max(sqrt(Double(cnt) / .pi) * 1.8, 3)
            dust += [(cx + Double(de.minX)) / 0.25, (cy + Double(de.minY)) / 0.25, rad / 0.25]
            if dust.count > 300 { break }
        } }
        return Profile(name: doc.url.deletingPathExtension().lastPathComponent, file: file, dust: dust)
    }

    /// Applies to a photo (source coordinates, before geometry). mode: 1 color cast, 2 light uniformity
    static func apply(_ img: CIImage, file: String, mode: Int, scale: CGFloat) -> CIImage {
        guard let map = Layers.sourceImage(file), map.extent.width > 0 else { return img }
        let e = img.extent
        let fitted = map.transformed(by: .init(scaleX: e.width / map.extent.width, y: e.height / map.extent.height))
            .transformed(by: .init(translationX: e.minX, y: e.minY)).clampedToExtent().cropped(to: e)
        return divK?.apply(extent: e, arguments: [img, fitted, Float(mode & 1), Float(mode & 2)]) ?? img
    }

    static let divK = CIColorKernel(source: """
        kernel vec4 k(__sample s, __sample m, float colorOn, float lightOn) {
            vec3 mm = max(m.rgb, vec3(0.05));
            float l = dot(mm, vec3(0.2627, 0.678, 0.0593));
            vec3 d = vec3(1.0);
            if (colorOn > 0.5) d *= mm / l;
            if (lightOn > 0.5) d *= l;
            return vec4(s.rgb / d, s.a);
        }
        """)
}

extension MainWindowController {
    @objc func makeLCC(_ sender: Any?) {
        guard let doc = photo, doc.isRaw, let p = LCC.make(from: doc) else { NSSound.beep(); return }
        var list = LCC.profiles.filter { $0.name != p.name }
        list.append(p)
        LCC.profiles = list
        let a = NSAlert()
        a.messageText = "LCC \"\(p.name)\"를 만들었습니다"
        a.informativeText = "먼지 \(p.dust.count / 3)개를 찾았습니다. 같은 렌즈·조리개로 찍은 사진을 고르고 사진 → LCC 적용을 쓰세요."
        a.runModal()
    }

    @objc func applyLCC(_ sender: Any?) {
        let list = LCC.profiles
        guard !list.isEmpty else { NSSound.beep(); return }
        let a = NSAlert()
        a.messageText = "LCC 적용"
        let pop = NSPopUpButton(); pop.addItems(withTitles: list.map(\.name)); pop.addItem(withTitle: "LCC 빼기")
        let color = NSButton(checkboxWithTitle: "색 편차 보정", target: nil, action: nil); color.state = .on
        let light = NSButton(checkboxWithTitle: "빛 균일화", target: nil, action: nil); light.state = .on
        let dust = NSButton(checkboxWithTitle: "먼지 지우기", target: nil, action: nil); dust.state = .on
        let st = NSStackView(views: [pop, color, light, dust]); st.orientation = .vertical; st.alignment = .leading
        st.frame = NSRect(x: 0, y: 0, width: 240, height: 100)
        a.accessoryView = st
        a.addButton(withTitle: "적용"); a.addButton(withTitle: "취소")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let prof = pop.indexOfSelectedItem < list.count ? list[pop.indexOfSelectedItem] : nil
        let mode = (color.state == .on ? 1 : 0) | (light.state == .on ? 2 : 0)
        for item in targetItems {
            func edit(_ s: inout DevelopSettings) {
                s.spots.removeAll { $0.opacity == 0.999 }   // LCC dust spots added earlier
                s.lcc = prof?.file
                s.lccMode = prof == nil ? nil : mode
                if let p = prof, dust.state == .on {
                    for j in stride(from: 0, to: p.dust.count - 2, by: 3) {
                        let r = p.dust[j + 2]
                        s.spots.append(RetouchSpot(kind: .heal, targetX: p.dust[j], targetY: p.dust[j + 1],
                                                   sourceX: p.dust[j] + r * 2.5, sourceY: p.dust[j + 1], radius: r, feather: 0.5, opacity: 0.999))
                    }
                }
            }
            if item === photoItem, var s = photo?.settings {
                edit(&s)
                replaceSettings(s, recordUndo: true, label: "LCC")
            } else if let d = try? RawDocument(url: item.url) {
                var s = library.loadSettings(for: item.url, over: d.asShot) ?? d.asShot
                edit(&s)
                library.saveSettings(s, asShot: d.asShot, for: item.url)
                refreshItem(item)
            }
        }
    }
}
