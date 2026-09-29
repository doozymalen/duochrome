import AppKit
import CoreImage
import UniformTypeIdentifiers

// MARK: - Document color space · bit depth · color modes (grayscale, duotone, CMYK, Lab) · channels · swatches

/// Document color mode (Image > Mode)
enum DocMode: Int, CaseIterable {
    case rgb, gray, duotone, cmyk, lab
    var title: String { ["RGB 색상", "회색조", "이중톤", "CMYK 색상", "Lab 색상"][rawValue] }
    /// Channel names (Channels panel)
    var channels: [String] {
        switch self {
        case .rgb: ["빨강", "초록", "파랑"]
        case .gray, .duotone: ["회색"]
        case .cmyk: ["녹청", "마젠타", "노랑", "검정"]
        case .lab: ["밝기", "a", "b"]
        }
    }
}

enum ColorModes {
    static let genericCMYKProfile = URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc")

    /// Applies document mode, color space, and bit depth as the last stage (working space linear Rec.2020 → same space)
    static func apply(_ s: DevelopSettings, _ input: CIImage) -> CIImage {
        var img = input
        let mode = DocMode(rawValue: s.docMode ?? 0) ?? .rgb
        // Convert to the document color space: out-of-gamut values are clipped
        if let name = s.docSpace, let sp = ExportRecipe.Space(rawValue: name), mode == .rgb || mode == .lab {
            img = clampTo(img, sp.cg, depth8: s.docDepth == 8)
        } else if s.docDepth == 8 {
            img = clampTo(img, CGColorSpace(name: CGColorSpace.sRGB)!, depth8: true)
        }
        switch mode {
        case .rgb, .lab: break
        case .gray:
            img = img.applyingFilter("CIColorMatrix", parameters: grayMatrix)
        case .duotone:
            let inks = (s.duotone ?? [0, 0, 0, 0.62, 0.42, 0.24]) + [0, 0, 0, 0, 0, 0]
            let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
            if let k = duotoneKernel, let g = img.applyingFilter("CIColorMatrix", parameters: grayMatrix).matchedFromWorkingSpace(to: srgb),
               let out = k.apply(extent: img.extent, arguments: [g, CIVector(x: CGFloat(inks[0]), y: CGFloat(inks[1]), z: CGFloat(inks[2])),
                                                                   CIVector(x: CGFloat(inks[3]), y: CGFloat(inks[4]), z: CGFloat(inks[5])),
                                                                   CGFloat(s.duotoneBalance ?? 0.5)]) {
                img = out.matchedToWorkingSpace(from: srgb) ?? img
            }
        case .cmyk:
            // Preview in CMYK gamut (generic CMYK profile round-trip)
            img = cmykRoundTrip(img)
        }
        return img.cropped(to: input.extent)
    }

    /// Gray from linear Rec.2020 luminance coefficients
    static let grayMatrix: [String: Any] = {
        let w = CIVector(x: 0.2627, y: 0.6780, z: 0.0593, w: 0)
        return ["inputRVector": w, "inputGVector": w, "inputBVector": w, "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)]
    }()

    /// Converts to a color space, clamps to 0–1 (256 levels if 8-bit), and converts back
    private static func clampTo(_ img: CIImage, _ cs: CGColorSpace, depth8: Bool) -> CIImage {
        guard let inS = img.matchedFromWorkingSpace(to: cs) else { return img }
        var c = inS.applyingFilter("CIColorClamp")
        if depth8 { c = c.applyingFilter("CIColorPosterize", parameters: ["inputLevels": 256]) }
        return c.matchedToWorkingSpace(from: cs) ?? img
    }

    /// Duotone: looks like two inks overprinted. The first ink covers all shadows, the second weights toward midtones
    private static let duotoneKernel = CIColorKernel(source: """
    kernel vec4 duotone(__sample s, vec3 ink1, vec3 ink2, float balance) {
        float g = clamp(s.r, 0.0, 1.0);
        float d1 = pow(1.0 - g, 1.0 + balance);
        float d2 = pow(1.0 - g, 0.6) * (1.0 - pow(1.0 - g, 3.0)) * 1.6;
        vec3 c = (vec3(1.0) - d1 * (vec3(1.0) - ink1)) * (vec3(1.0) - clamp(d2, 0.0, 1.0) * (vec3(1.0) - ink2));
        return vec4(c, s.a);
    }
    """)

    // MARK: CMYK

    private static var cmykCube: (String, Data)?

    /// Profile used by CMYK mode: the proof profile if it's CMYK (press profile), otherwise macOS generic CMYK
    static var cmykSpace: CGColorSpace {
        if let url = ProofProfile.current, let d = try? Data(contentsOf: url), let cs = CGColorSpace(iccData: d as CFData), cs.model == .cmyk { return cs }
        return CGColorSpace(name: CGColorSpace.genericCMYK)!
    }
    static var cmykName: String { ProofProfile.current.flatMap { u in (try? Data(contentsOf: u)).flatMap { CGColorSpace(iccData: $0 as CFData) }?.model == .cmyk ? u.lastPathComponent : nil } ?? "일반 CMYK" }
    /// sRGB → generic CMYK → sRGB round-trip grid (25³), converted by Core Graphics via ColorSync
    static func cmykCubeData(n: Int = 25) -> Data? {
        if let c = cmykCube, c.0 == cmykName { return c.1 }
        let w = n * n, h = n
        var rgb = [UInt8](repeating: 255, count: w * h * 4)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let i = (g * w + b * n + r) * 4
            rgb[i] = UInt8(r * 255 / (n - 1)); rgb[i + 1] = UInt8(g * 255 / (n - 1)); rgb[i + 2] = UInt8(b * 255 / (n - 1))
        } } }
        let cmyk = cmykSpace
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let src = CGContext(data: &rgb, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let srcImage = src.makeImage(),
              let cctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cmyk,
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        cctx.interpolationQuality = .none
        cctx.draw(srcImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let cmykImage = cctx.makeImage() else { return nil }
        var back = [UInt8](repeating: 0, count: w * h * 4)
        guard let bctx = CGContext(data: &back, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        bctx.interpolationQuality = .none
        bctx.draw(cmykImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Core Graphics y is bottom-up, but a grid drawn top-down comes back in the same place, so order is unchanged
        var cube = [Float](repeating: 1, count: n * n * n * 4)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let i = (g * w + b * n + r) * 4, o = (b * n * n + g * n + r) * 4
            cube[o] = Float(back[i]) / 255; cube[o + 1] = Float(back[i + 1]) / 255; cube[o + 2] = Float(back[i + 2]) / 255
        } } }
        let d = cube.withUnsafeBufferPointer { Data(buffer: $0) }
        cmykCube = (cmykName, d)
        return d
    }

    static func cmykRoundTrip(_ img: CIImage) -> CIImage {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cube = cmykCubeData(), let inS = img.matchedFromWorkingSpace(to: srgb) else { return img }
        let out = inS.applyingFilter("CIColorClamp").applyingFilter("CIColorCube", parameters: ["inputCubeDimension": 25, "inputCubeData": cube])
        return out.matchedToWorkingSpace(from: srgb) ?? img
    }

    // MARK: Export

    /// Converts the export image for the document mode: grayscale/duotone → gray (duotone keeps its color), CMYK → CMYK (TIFF/JPEG), Lab → Lab (TIFF)
    static func convertForExport(_ cg: CGImage, mode: DocMode, format: ExportRecipe.Format) -> CGImage {
        switch mode {
        case .gray:
            return redraw(cg, space: CGColorSpaceCreateDeviceGray(), components: 1, info: CGImageAlphaInfo.none.rawValue,
                          sixteen: cg.bitsPerComponent > 8) ?? cg
        case .cmyk where [.tiff8, .tiff16, .jpeg].contains(format):
            return redraw(cg, space: cmykSpace, components: 4, info: CGImageAlphaInfo.none.rawValue, sixteen: cg.bitsPerComponent > 8 && format != .jpeg) ?? cg
        case .lab where [.tiff8, .tiff16].contains(format):
            return labImage(cg) ?? cg
        default: return cg
        }
    }

    private static func redraw(_ cg: CGImage, space: CGColorSpace, components: Int, info: UInt32, sixteen: Bool) -> CGImage? {
        let bpc = sixteen ? 16 : 8
        var bi = info
        if sixteen { bi |= CGBitmapInfo.byteOrder16Little.rawValue }
        guard let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: bpc,
                                  bytesPerRow: cg.width * components * bpc / 8, space: space, bitmapInfo: bi) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return ctx.makeImage()
    }

    /// sRGB image → CIE Lab (D50) 8-bit image (L 0–255, a/b with 128 as 0)
    static func labImage(_ cg: CGImage) -> CGImage? {
        let w = cg.width, h = cg.height
        var rgb = [UInt8](repeating: 0, count: w * h * 4)
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &rgb, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var lab = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            let (L, a, b) = toLab(Float(rgb[i * 4]) / 255, Float(rgb[i * 4 + 1]) / 255, Float(rgb[i * 4 + 2]) / 255)
            lab[i * 3] = UInt8(max(0, min(255, L * 2.55)))
            lab[i * 3 + 1] = UInt8(max(0, min(255, a + 128)))
            lab[i * 3 + 2] = UInt8(max(0, min(255, b + 128)))
        }
        let white: [CGFloat] = [0.9642, 1, 0.8249], black: [CGFloat] = [0, 0, 0], range: [CGFloat] = [-128, 127, -128, 127]
        guard let space = CGColorSpace(labWhitePoint: white, blackPoint: black, range: range),
              let provider = CGDataProvider(data: Data(lab) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: w * 3, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    /// sRGB (gamma) → Lab D50
    static func toLab(_ r0: Float, _ g0: Float, _ b0: Float) -> (Float, Float, Float) {
        func lin(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let r = lin(r0), g = lin(g0), b = lin(b0)
        // sRGB → XYZ D50 (Bradford adaptation)
        let x = 0.4360747 * r + 0.3850649 * g + 0.1430804 * b
        let y = 0.2225045 * r + 0.7168786 * g + 0.0606169 * b
        let z = 0.0139322 * r + 0.0971045 * g + 0.7141733 * b
        func f(_ t: Float) -> Float { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
        let fx = f(x / 0.9642), fy = f(y), fz = f(z / 0.8249)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    // MARK: Channel view

    /// One channel as gray (0 keeps the composite). RGB: red/green/blue, CMYK: cyan/magenta/yellow/black (more ink is darker), Lab: L/a/b
    static func channelView(_ img: CIImage, mode: DocMode, channel: Int) -> CIImage {
        guard channel > 0, channel <= mode.channels.count, mode != .gray, mode != .duotone else { return img }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let k = channelKernel, let inS = img.matchedFromWorkingSpace(to: srgb),
              let out = k.apply(extent: img.extent, arguments: [inS.applyingFilter("CIColorClamp"), CGFloat(mode.rawValue), CGFloat(channel)]) else { return img }
        return out.matchedToWorkingSpace(from: srgb) ?? img
    }

    private static let channelKernel = CIColorKernel(source: """
    kernel vec4 channel(__sample s, float mode, float ch) {
        vec3 c = s.rgb;
        float v = 0.0;
        if (mode < 0.5) {
            v = ch < 1.5 ? c.r : (ch < 2.5 ? c.g : c.b);
        } else if (mode < 3.5) {
            float k = 1.0 - max(c.r, max(c.g, c.b));
            float d = max(1.0 - k, 0.0001);
            float ink = ch < 1.5 ? (1.0 - c.r - k) / d : (ch < 2.5 ? (1.0 - c.g - k) / d : (ch < 3.5 ? (1.0 - c.b - k) / d : k));
            v = 1.0 - ink;
        } else {
            vec3 l = vec3(c.r <= 0.04045 ? c.r / 12.92 : pow((c.r + 0.055) / 1.055, 2.4),
                          c.g <= 0.04045 ? c.g / 12.92 : pow((c.g + 0.055) / 1.055, 2.4),
                          c.b <= 0.04045 ? c.b / 12.92 : pow((c.b + 0.055) / 1.055, 2.4));
            float x = dot(l, vec3(0.4360747, 0.3850649, 0.1430804)) / 0.9642;
            float y = dot(l, vec3(0.2225045, 0.7168786, 0.0606169));
            float z = dot(l, vec3(0.0139322, 0.0971045, 0.7141733)) / 0.8249;
            float fx = x > 0.008856 ? pow(x, 1.0 / 3.0) : 7.787 * x + 16.0 / 116.0;
            float fy = y > 0.008856 ? pow(y, 1.0 / 3.0) : 7.787 * y + 16.0 / 116.0;
            float fz = z > 0.008856 ? pow(z, 1.0 / 3.0) : 7.787 * z + 16.0 / 116.0;
            v = ch < 1.5 ? (116.0 * fy - 16.0) / 100.0 : (ch < 2.5 ? (500.0 * (fx - fy) + 128.0) / 255.0 : (200.0 * (fy - fz) + 128.0) / 255.0);
        }
        v = clamp(v, 0.0, 1.0);
        return vec4(v, v, v, s.a);
    }
    """)
}

// MARK: - Window actions (menus)

extension MainWindowController {
    @objc func setDocMode(_ sender: NSMenuItem) {
        guard var s = photo?.settings, let m = DocMode(rawValue: sender.tag) else { NSSound.beep(); return }
        if m == .duotone, s.duotone == nil { s.duotone = [0, 0, 0, 0.62, 0.42, 0.24] }
        s.docMode = m == .rgb ? nil : m.rawValue
        canvas.channelView = 0
        replaceSettings(s, recordUndo: true, label: "모드: \(m.title)")
    }

    @objc func setDocSpace(_ sender: NSMenuItem) {
        guard var s = photo?.settings else { NSSound.beep(); return }
        let spaces = ExportRecipe.Space.allCases
        s.docSpace = sender.tag < 0 ? nil : spaces[sender.tag].rawValue
        replaceSettings(s, recordUndo: true, label: "색 공간 변환")
    }

    @objc func setDocDepth(_ sender: NSMenuItem) {
        guard var s = photo?.settings else { NSSound.beep(); return }
        s.docDepth = sender.tag == 16 ? nil : sender.tag
        replaceSettings(s, recordUndo: true, label: "\(sender.tag)비트")
    }

    /// Pick duotone inks (from preset pairs, not the color panel)
    @objc func setDuotoneInks(_ sender: NSMenuItem) {
        guard var s = photo?.settings else { return }
        let presets: [[Float]] = [[0, 0, 0, 0.62, 0.42, 0.24], [0, 0, 0, 0.25, 0.4, 0.65], [0.1, 0.05, 0.2, 0.85, 0.55, 0.3], [0, 0, 0, 0.55, 0.55, 0.5]]
        s.duotone = presets[max(0, min(presets.count - 1, sender.tag))]
        s.docMode = DocMode.duotone.rawValue
        replaceSettings(s, recordUndo: true, label: "이중톤 잉크")
    }

    @objc func showChannel(_ sender: NSMenuItem) {
        canvas.channelView = sender.tag
    }

    /// Split channels: each channel as a 16-bit gray PNG (choose a folder)
    @objc func splitChannels(_ sender: Any?) {
        guard photo != nil else { NSSound.beep(); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "채널 파일을 저장할 폴더를 고르세요"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do { _ = try writeChannels(to: dir) } catch { NSSound.beep() }
    }

    /// Writes the channel files (also called from tests)
    func writeChannels(to dir: URL) throws -> [URL] {
        guard let doc = photo else { return [] }
        let mode = DocMode(rawValue: doc.settings.docMode ?? 0) ?? .rgb
        let img = doc.withFullResolution { doc.image(scale: 1) }
        var out: [URL] = []
        let names = mode == .gray || mode == .duotone ? ["회색"] : mode.channels
        for (i, name) in names.enumerated() {
            let ch = mode == .gray || mode == .duotone ? img : ColorModes.channelView(img, mode: mode, channel: i + 1)
            let gray = ch.applyingFilter("CIColorMatrix", parameters: ColorModes.grayMatrix)
            let url = dir.appendingPathComponent((doc.url.deletingPathExtension().lastPathComponent) + "_" + name + ".png")
            try Render.context.writePNGRepresentation(of: gray, to: url, format: .L16, colorSpace: CGColorSpace(name: CGColorSpace.linearGray)!)
            out.append(url)
        }
        return out
    }

    /// Merge channels: combine three gray images as red/green/blue into an image layer
    @objc func mergeChannels(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.message = "빨강·초록·파랑 순서로 회색 그림 셋을 고르세요 (이름순)"
        guard panel.runModal() == .OK else { return }
        mergeChannelFiles(panel.urls.sorted { $0.lastPathComponent < $1.lastPathComponent })
    }

    func mergeChannelFiles(_ urls: [URL]) {
        guard urls.count >= 3, let doc = photo else { NSSound.beep(); return }
        let imgs = urls.prefix(3).compactMap { CIImage(contentsOf: $0) }
        guard imgs.count == 3 else { NSSound.beep(); return }
        let e = imgs[0].extent
        func only(_ i: CIImage, _ v: CIVector) -> CIImage {
            i.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: v.x, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: v.y, z: 0, w: 0),
                                                            "inputBVector": CIVector(x: 0, y: 0, z: v.z, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        }
        let r = only(imgs[0], CIVector(x: 1, y: 0, z: 0)), g = only(imgs[1], CIVector(x: 0, y: 1, z: 0)), b = only(imgs[2], CIVector(x: 0, y: 0, z: 1))
        let rgb = r.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: g])
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: b]).cropped(to: e)
        guard let png = Render.context.pngRepresentation(of: rgb, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
              let file = try? LayerImageStore.importData(png, ext: "png"), var s = photo?.settings else { NSSound.beep(); return }
        var l = AdjustLayer(name: "채널 합치기")
        l.kind = "image"
        let n = doc.nativeSize
        l.image = LayerImage(file: file, cx: Double(n.width) / 2, cy: Double(n.height) / 2, width: Double(n.width))
        s.layers.append(l)
        replaceSettings(s, recordUndo: true, label: "채널 합치기")
        layersTab.select(l.id)
        if mode == .studio { studioMode.layersPanel.reload() }
    }

    /// Color mode menu (under the Image menu)
    func colorModeMenu() -> NSMenu {
        let m = NSMenu(title: "모드")
        for mode in DocMode.allCases {
            let item = m.addItem(withTitle: mode.title, action: #selector(setDocMode(_:)), keyEquivalent: "")
            item.tag = mode.rawValue
            item.target = self
        }
        m.addItem(.separator())
        let duo = m.addItem(withTitle: "이중톤 잉크", action: nil, keyEquivalent: "")
        let dm = NSMenu()
        for (i, t) in ["검정 + 세피아", "검정 + 청회색", "보라 + 황금", "검정 + 따뜻한 회색"].enumerated() {
            let it = dm.addItem(withTitle: t, action: #selector(setDuotoneInks(_:)), keyEquivalent: ""); it.tag = i; it.target = self
        }
        duo.submenu = dm
        m.addItem(.separator())
        for (tag, t) in [(8, "8비트/채널"), (16, "16비트/채널"), (32, "32비트/채널 (1.0 넘는 밝기 보존)")] {
            let it = m.addItem(withTitle: t, action: #selector(setDocDepth(_:)), keyEquivalent: ""); it.tag = tag; it.target = self
        }
        m.addItem(.separator())
        let cs = m.addItem(withTitle: "색 공간으로 변환", action: nil, keyEquivalent: "")
        let csm = NSMenu()
        let none = csm.addItem(withTitle: "변환 안 함 (작업 공간 그대로)", action: #selector(setDocSpace(_:)), keyEquivalent: ""); none.tag = -1; none.target = self
        for (i, sp) in ExportRecipe.Space.allCases.enumerated() {
            let it = csm.addItem(withTitle: sp.title, action: #selector(setDocSpace(_:)), keyEquivalent: ""); it.tag = i; it.target = self
        }
        cs.submenu = csm
        m.addItem(.separator())
        let ch = m.addItem(withTitle: "채널 보기", action: nil, keyEquivalent: "")
        ch.submenu = channelMenu()
        m.addItem(withTitle: "채널 분리…", action: #selector(splitChannels(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "채널 합치기…", action: #selector(mergeChannels(_:)), keyEquivalent: "").target = self
        return m
    }

    func channelMenu() -> NSMenu {
        let m = NSMenu(title: "채널")
        let mode = DocMode(rawValue: photo?.settings.docMode ?? 0) ?? .rgb
        let comp = m.addItem(withTitle: "합성 (\(mode.title))", action: #selector(showChannel(_:)), keyEquivalent: "2")
        comp.tag = 0; comp.target = self; comp.keyEquivalentModifierMask = [.command]
        for (i, name) in mode.channels.enumerated() where mode != .gray && mode != .duotone {
            let it = m.addItem(withTitle: name, action: #selector(showChannel(_:)), keyEquivalent: "\(i + 3)")
            it.tag = i + 1; it.target = self; it.keyEquivalentModifierMask = [.command]
        }
        return m
    }

    /// View as HDR (brightness above 1.0 on EDR displays)
    @objc func toggleHDRView(_ sender: Any?) {
        canvas.hdrView.toggle()
        UserDefaults.standard.set(canvas.hdrView, forKey: "view.hdr")
    }
}

// MARK: - Swatches (under picker options)

final class SwatchesView: NSView {
    /// When a swatch is clicked (display RGB)
    var onPick: (([Float]) -> Void)?
    /// Color to add for "Add Current Color"
    var current: (() -> [Float]?)?

    static var saved: [[Float]] {
        get { (UserDefaults.standard.array(forKey: "swatches") as? [[Double]])?.map { $0.map(Float.init) } ?? defaults }
        set { UserDefaults.standard.set(newValue.map { $0.map(Double.init) }, forKey: "swatches") }
    }
    static let defaults: [[Float]] = [[0, 0, 0], [1, 1, 1], [0.5, 0.5, 0.5], [0.9, 0.2, 0.2], [0.95, 0.6, 0.15], [0.95, 0.85, 0.2],
                                      [0.3, 0.75, 0.35], [0.2, 0.6, 0.9], [0.45, 0.3, 0.8], [0.62, 0.42, 0.24]]
    private let cell: CGFloat = 20

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        let cols = max(1, Int((bounds.width > 0 ? bounds.width : 220) / (cell + 4)))
        let rows = (Self.saved.count + 1 + cols - 1) / cols
        return NSSize(width: NSView.noIntrinsicMetric, height: CGFloat(rows) * (cell + 4))
    }
    override func layout() { super.layout(); invalidateIntrinsicContentSize() }

    private func frames() -> [NSRect] {
        let cols = max(1, Int(bounds.width / (cell + 4)))
        return (0...Self.saved.count).map { i in NSRect(x: CGFloat(i % cols) * (cell + 4), y: CGFloat(i / cols) * (cell + 4), width: cell, height: cell) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let f = frames()
        for (i, c) in Self.saved.enumerated() {
            NSColor(srgbRed: CGFloat(c[0]), green: CGFloat(c[1]), blue: CGFloat(c[2]), alpha: 1).setFill()
            NSBezierPath(roundedRect: f[i], xRadius: 4, yRadius: 4).fill()
            NSColor.white.withAlphaComponent(0.2).setStroke()
            NSBezierPath(roundedRect: f[i].insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4).stroke()
        }
        // last cell: add
        let plus = f[Self.saved.count]
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: plus, xRadius: 4, yRadius: 4).fill()
        let p = NSBezierPath()
        p.move(to: NSPoint(x: plus.midX - 5, y: plus.midY)); p.line(to: NSPoint(x: plus.midX + 5, y: plus.midY))
        p.move(to: NSPoint(x: plus.midX, y: plus.midY - 5)); p.line(to: NSPoint(x: plus.midX, y: plus.midY + 5))
        NSColor.secondaryLabelColor.setStroke(); p.lineWidth = 1.5; p.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard let i = frames().firstIndex(where: { $0.contains(pt) }) else { return }
        if i == Self.saved.count {
            if let c = current?() { Self.saved.append(c); invalidateIntrinsicContentSize(); needsDisplay = true }
        } else if event.modifierFlags.contains(.option) {
            // ⌥-click: delete swatch
            var s = Self.saved; s.remove(at: i); Self.saved = s; invalidateIntrinsicContentSize(); needsDisplay = true
        } else {
            onPick?(Self.saved[i])
        }
    }
}

extension MainWindowController {
    /// Applies the swatch color where it's in use: paint brush, selected text layer, selected shape layer (fill)
    func applySwatch(_ c: [Float]) {
        var b = PaintBrush.current; b.color = c; PaintBrush.current = b
        VectorToolState.shared.color = c
        VectorToolState.shared.fill = c
        if let s = photo?.settings, let id = layersTab.selectedID, let l = s.layers.first(where: { $0.id == id }) {
            if l.isText { editSelectedText { $0.color = c } }
            if l.kind == "shape" { applyShapeOptionsToSelection() }
        }
        paintOptions.reload()
    }
}

/// Mode menu: rebuilt from the current document's mode and channels each time it opens
final class ColorModeMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = ColorModeMenuDelegate()
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let w = NSApp.windows.compactMap({ $0.windowController as? MainWindowController }).first else { return }
        let built = w.colorModeMenu()
        let mode = w.photo?.settings.docMode ?? 0
        for item in built.items {
            built.removeItem(item)
            if item.action == #selector(MainWindowController.setDocMode(_:)) { item.state = item.tag == mode ? .on : .off }
            if item.action == #selector(MainWindowController.setDocDepth(_:)) { item.state = item.tag == (w.photo?.settings.docDepth ?? 16) ? .on : .off }
            menu.addItem(item)
        }
    }
}
