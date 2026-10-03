import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Export settings (one recipe).
struct ExportRecipe: Codable, Equatable {
    enum Format: String, Codable, CaseIterable {
        case tiff16, tiff8, jpeg, png, heic, tiff32
        var title: String {
            switch self {
            case .tiff16: "TIFF 16비트"
            case .tiff8: "TIFF 8비트"
            case .jpeg: "JPEG"
            case .png: "PNG"
            case .heic: "HEIC"
            case .tiff32: "TIFF 32비트 (부동소수점, HDR)"
            }
        }
        var ext: String { switch self { case .tiff16, .tiff8, .tiff32: "tif"; case .jpeg: "jpg"; case .png: "png"; case .heic: "heic" } }
        var type: UTType { switch self { case .tiff16, .tiff8, .tiff32: .tiff; case .jpeg: .jpeg; case .png: .png; case .heic: .heic } }
        var sixteenBit: Bool { self == .tiff16 || self == .png }
    }
    enum Space: String, Codable, CaseIterable {
        case sRGB, displayP3, adobeRGB, proPhoto
        var title: String { ["sRGB", "Display P3", "Adobe RGB (1998)", "ProPhoto RGB"][Self.allCases.firstIndex(of: self)!] }
        var cg: CGColorSpace {
            switch self {
            case .sRGB: CGColorSpace(name: CGColorSpace.sRGB)!
            case .displayP3: CGColorSpace(name: CGColorSpace.displayP3)!
            case .adobeRGB: CGColorSpace(name: CGColorSpace.adobeRGB1998)!
            case .proPhoto: CGColorSpace(name: CGColorSpace.rommrgb)!
            }
        }
    }

    var format: Format = .jpeg
    var quality: Double = 0.9
    var space: Space = .sRGB
    /// Long side in pixels. 0 means original size.
    var longSide: Int = 0
    /// Output sharpening 0 none – 3 strong (applied after resizing for screen/print).
    var sharpen: Int = 1
    var folder: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Duochrome/Export").path
    var suffix: String = ""
    var keepMetadata = true
    /// Watermark text (empty = none), size (% of long side), opacity, position (0 bottom-left, 1 bottom-right, 2 top-left, 3 top-right, 4 center)
    var watermark = ""
    var watermarkSize: Double = 2.5
    var watermarkOpacity: Double = 0.7
    var watermarkCorner = 1
    /// Recipe name (saved recipe list), naming rule ({이름} {날짜} {번호} …; empty keeps the original name), subfolder under the folder
    var name: String? = nil
    var namePattern: String? = nil
    var subfolder: String? = nil

    /// Saved recipes (several)
    static var library: [ExportRecipe] {
        get { (UserDefaults.standard.data(forKey: "exportRecipes").flatMap { try? JSONDecoder().decode([ExportRecipe].self, from: $0) }) ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "exportRecipes") }
    }

    static var saved: ExportRecipe {
        (UserDefaults.standard.data(forKey: "exportRecipe").flatMap { try? JSONDecoder().decode(ExportRecipe.self, from: $0) }) ?? ExportRecipe()
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "exportRecipe") }
}

enum Exporter {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    /// Watermark: white text at a % of the long side, inset slightly from the edge (with a faint shadow so it shows on bright areas).
    static func watermarked(_ img: CIImage, _ r: ExportRecipe) -> CIImage {
        let e = img.extent
        let px = max(CGFloat(r.watermarkSize) / 100 * max(e.width, e.height), 10)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = px * 0.08
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: px, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(CGFloat(r.watermarkOpacity)), .shadow: shadow,
        ]
        let text = NSAttributedString(string: r.watermark, attributes: attrs)
        let ts = text.size()
        let w = Int(ceil(ts.width + px)), h = Int(ceil(ts.height + px * 0.5))
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        text.draw(at: NSPoint(x: px * 0.5, y: px * 0.25))
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return img }
        let margin = max(e.width, e.height) * 0.02
        let x: CGFloat, y: CGFloat
        switch r.watermarkCorner {
        case 0: x = e.minX + margin; y = e.minY + margin
        case 2: x = e.minX + margin; y = e.maxY - margin - CGFloat(h)
        case 3: x = e.maxX - margin - CGFloat(w); y = e.maxY - margin - CGFloat(h)
        case 4: x = e.midX - CGFloat(w) / 2; y = e.midY - CGFloat(h) / 2
        default: x = e.maxX - margin - CGFloat(w); y = e.minY + margin
        }
        let mark = CIImage(cgImage: cg).transformed(by: .init(translationX: x, y: y))
        return mark.composited(over: img).cropped(to: e)
    }

    /// Writes one document to a file per the recipe. Returns the result path. (Safe in the background, assuming only this thread uses the document)
    static func export(_ doc: RawDocument, recipe r: ExportRecipe, name: String) throws -> URL {
        try BackgroundGate.during { try doc.withFullResolution { try exportNow(doc, recipe: r, name: name) } }
    }

    private static func exportNow(_ doc: RawDocument, recipe r: ExportRecipe, name: String) throws -> URL {
        let wasFull = doc.showFullFrame, wasDraft = doc.draft
        doc.showFullFrame = false
        doc.draft = false
        defer { doc.showFullFrame = wasFull; doc.draft = wasDraft }
        doc.settleForExport()
        var img = doc.image(scale: 1)
        let size = img.extent.size
        // Size: the recipe's long side first, else the document's image size (resampling per document settings)
        var k: CGFloat = 1
        if r.longSide > 0, max(size.width, size.height) > CGFloat(r.longSide) {
            k = CGFloat(r.longSide) / max(size.width, size.height)
        } else if r.longSide == 0, let o = doc.settings.outputSize, o.count == 2, o[0] > 0 {
            k = CGFloat(o[0]) / size.width
        }
        if abs(k - 1) > 1e-4 { img = resample(img, k, method: doc.settings.resample ?? 0) }
        let rect = img.extent.integral
        img = img.cropped(to: rect).transformed(by: .init(translationX: -rect.minX, y: -rect.minY))
        // Output sharpening: small-radius unsharp mask matched to the output size.
        if r.sharpen > 0 {
            let amount = [0, 0.3, 0.55, 0.85][min(r.sharpen, 3)]
            img = img.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 0.8, kCIInputIntensityKey: amount])
                .cropped(to: img.extent)
        }
        if !r.watermark.isEmpty { img = watermarked(img, r) }
        // Background-removed photo: formats without transparency (JPEG) are placed on white
        let keepAlpha = doc.settings.cutout != nil && r.format != .jpeg
        if doc.settings.cutout != nil && !keepAlpha {
            img = img.composited(over: CIImage(color: .white).cropped(to: img.extent))
        }
        let format: CIFormat = r.format == .tiff32 ? .RGBAf : (r.format.sixteenBit ? .RGBA16 : .RGBA8)
        // 32-bit: extended linear space so brightness above 1.0 isn't clipped
        let space = r.format == .tiff32 ? (CGColorSpaceCreateExtendedLinearized(r.space.cg) ?? r.space.cg) : r.space.cg
        guard let withAlpha = Render.exportContext.createCGImage(img, from: img.extent, format: format, colorSpace: space) else {
            throw Failure(message: "\(name): 그리기 실패")
        }
        // Photos have no transparency. Mark alpha as "skip" and write RGB only (16-bit TIFF 335 MB → about 3/4).
        var cg = r.format == .tiff32 || keepAlpha ? withAlpha : (dropAlpha(withAlpha) ?? withAlpha)
        // Document mode: write as grayscale / CMYK / Lab
        if let m = doc.settings.docMode.flatMap(DocMode.init), m != .rgb, r.format != .tiff32 {
            cg = ColorModes.convertForExport(cg, mode: m, format: r.format)
        }
        var dir = URL(fileURLWithPath: r.folder, isDirectory: true)
        if let sub = r.subfolder, !sub.isEmpty { dir = dir.appendingPathComponent(sub, isDirectory: true) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = (name as NSString).deletingPathExtension + r.suffix
        var out = dir.appendingPathComponent(base).appendingPathExtension(r.format.ext)
        var n = 2
        while FileManager.default.fileExists(atPath: out.path) {
            out = dir.appendingPathComponent("\(base)-\(n)").appendingPathExtension(r.format.ext); n += 1
        }
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, r.format.type.identifier as CFString, 1, nil) else {
            throw Failure(message: "\(out.lastPathComponent): 파일을 만들 수 없음")
        }
        var props: [CFString: Any] = [:]
        if r.keepMetadata, let src = CGImageSourceCreateWithURL(doc.url as CFURL, nil),
           let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                        kCGImagePropertyExifAuxDictionary] {
                if let v = p[key] { props[key] = v }
            }
            if var tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                tiff[kCGImagePropertyTIFFSoftware] = "Duochrome"
                props[kCGImagePropertyTIFFDictionary] = tiff
            }
        }
        // Orientation already applied, so orientation is 1 (as is).
        props[kCGImagePropertyOrientation] = 1
        if r.format == .jpeg || r.format == .heic { props[kCGImageDestinationLossyCompressionQuality] = r.quality }
        if r.format == .tiff16 || r.format == .tiff8 || r.format == .tiff32 {
            props[kCGImagePropertyTIFFDictionary] = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:])
                .merging([kCGImagePropertyTIFFCompression: 8], uniquingKeysWith: { $1 })   // ZIP (Deflate) — for 16-bit photos LZW actually grew the file (306 MB > 268 MB uncompressed)
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure(message: "\(out.lastPathComponent): 쓰기 실패") }
        Render.exportContext.clearCaches()
        return out
    }
}

extension Exporter {
    /// Resampling: 0 Lanczos, 1 bicubic, 2 preserve details (Lanczos + small-radius unsharp), 3 nearest neighbor
    static func resample(_ img: CIImage, _ k: CGFloat, method: Int) -> CIImage {
        let e = img.extent
        switch method {
        case 1:
            return img.applyingFilter("CIBicubicScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1, "inputB": 0, "inputC": 0.75])
                .cropped(to: CGRect(x: (e.minX * k).rounded(), y: (e.minY * k).rounded(), width: (e.width * k).rounded(), height: (e.height * k).rounded()))
        case 2:
            let l = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1])
            return l.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: max(0.6, 0.8 * k), kCIInputIntensityKey: k > 1 ? 0.6 : 0.3]).cropped(to: l.extent)
        case 3:
            return img.samplingNearest().transformed(by: .init(scaleX: k, y: k)).cropped(to: CGRect(x: e.minX * k, y: e.minY * k, width: (e.width * k).rounded(), height: (e.height * k).rounded()))
        default: return img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1])
        }
    }

    /// Re-reads the same pixel data as "no alpha (skip last channel)". Alpha is all 1, so values are unchanged.
    static func dropAlpha(_ img: CGImage) -> CGImage? {
        guard let provider = img.dataProvider, let space = img.colorSpace else { return nil }
        let order = img.bitmapInfo.intersection(.byteOrderMask)
        var info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue).union(order)
        if img.bitmapInfo.contains(.floatComponents) { info.insert(.floatComponents) }
        return CGImage(width: img.width, height: img.height, bitsPerComponent: img.bitsPerComponent,
                       bitsPerPixel: img.bitsPerPixel, bytesPerRow: img.bytesPerRow, space: space, bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Export sheet. Choose format, color space, size, sharpening, folder; multiple photos are written in turn.
final class ExportSheet: NSWindowController {
    private var recipe = ExportRecipe.saved
    private let format = NSPopUpButton()
    private let quality = NSSlider(value: 90, minValue: 50, maxValue: 100, target: nil, action: nil)
    private let qualityLabel = NSTextField(labelWithString: "")
    private let space = NSPopUpButton()
    private let size = NSPopUpButton()
    private let sharpen = NSPopUpButton()
    private let folderLabel = NSTextField(labelWithString: "")
    private let suffix = NSTextField(string: "")
    private let meta = NSButton(checkboxWithTitle: "촬영 정보(EXIF·GPS) 넣기", target: nil, action: nil)
    private let mark = NSTextField(string: "")
    private let markSize = NSPopUpButton()
    private let markCorner = NSPopUpButton()
    private let namePattern = NSTextField(string: "")
    private let recipePopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let alsoPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private var also = Set<String>(UserDefaults.standard.stringArray(forKey: "exportAlso") ?? [])
    private let progress = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "")
    private let go = NSButton(title: "내보내기", target: nil, action: nil)
    private var jobs: [(PhotoItem, RawDocument?)] = []
    var library: Library?
    var onDone: (([URL]) -> Void)?
    static let sizes = [0, 6000, 4096, 3000, 2048, 1600, 1080]

    convenience init(count: Int) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        self.init(window: w)
        build(count: count)
    }

    private func row(_ title: String, _ v: NSView) -> NSStackView {
        let l = NSTextField(labelWithString: title)
        l.alignment = .right
        l.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let s = NSStackView(views: [l, v])
        s.spacing = 10
        return s
    }

    private func build(count: Int) {
        if let f = ProcessInfo.processInfo.environment["DUOCHROME_EXPORT_FOLDER"] { recipe.folder = f }   // for tests
        for f in ExportRecipe.Format.allCases { format.addItem(withTitle: f.title) }
        format.selectItem(at: ExportRecipe.Format.allCases.firstIndex(of: recipe.format) ?? 0)
        for s in ExportRecipe.Space.allCases { space.addItem(withTitle: s.title) }
        space.selectItem(at: ExportRecipe.Space.allCases.firstIndex(of: recipe.space) ?? 0)
        for s in Self.sizes { size.addItem(withTitle: s == 0 ? "원본 크기" : "긴 변 \(s)px") }
        size.selectItem(at: Self.sizes.firstIndex(of: recipe.longSide) ?? 0)
        for s in ["출력 샤프닝 없음", "약하게 (화면)", "보통", "강하게 (인쇄)"] { sharpen.addItem(withTitle: s) }
        sharpen.selectItem(at: recipe.sharpen)
        quality.doubleValue = recipe.quality * 100
        quality.target = self; quality.action = #selector(qualityChanged)
        format.target = self; format.action = #selector(qualityChanged)
        qualityChanged()
        folderLabel.stringValue = recipe.folder
        folderLabel.lineBreakMode = .byTruncatingHead
        folderLabel.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let pick = NSButton(title: "바꾸기…", target: self, action: #selector(pickFolder))
        suffix.stringValue = recipe.suffix
        suffix.placeholderString = "예: _web"
        suffix.widthAnchor.constraint(equalToConstant: 140).isActive = true
        meta.state = recipe.keepMetadata ? .on : .off
        mark.stringValue = recipe.watermark
        mark.placeholderString = "예: © doozymalen.com"
        mark.widthAnchor.constraint(equalToConstant: 180).isActive = true
        for s in [1.5, 2.5, 4, 6] { markSize.addItem(withTitle: "긴 변의 \(s)%"); markSize.lastItem?.representedObject = s }
        markSize.selectItem(at: [1.5, 2.5, 4, 6].firstIndex(of: recipe.watermarkSize) ?? 1)
        markCorner.addItems(withTitles: ["왼쪽 아래", "오른쪽 아래", "왼쪽 위", "오른쪽 위", "가운데"])
        markCorner.selectItem(at: recipe.watermarkCorner)
        progress.isIndeterminate = false
        progress.isHidden = true
        status.textColor = .secondaryLabelColor
        go.target = self; go.action = #selector(start); go.keyEquivalent = "\r"
        let cancel = NSButton(title: "닫기", target: self, action: #selector(close(_:)))
        cancel.keyEquivalent = "\u{1b}"
        namePattern.stringValue = recipe.namePattern ?? ""
        namePattern.placeholderString = "이름 규칙 (비우면 그대로): {이름}_{날짜}"
        namePattern.widthAnchor.constraint(equalToConstant: 220).isActive = true
        rebuildRecipeMenus()
        let title = NSTextField(labelWithString: count == 1 ? "사진 1장 내보내기" : "사진 \(count)장 내보내기")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let buttons = NSStackView(views: [NSView(), cancel, go])
        let stack = NSStackView(views: [title,
                                        row("형식", format), row("품질", NSStackView(views: [quality, qualityLabel])),
                                        row("색 공간", space), row("크기", size), row("샤프닝", sharpen),
                                        row("레시피", NSStackView(views: [recipePopup, alsoPopup])),
                                        row("폴더", NSStackView(views: [folderLabel, pick])), row("이름 뒤에 붙일 말", suffix),
                                        row("이름 규칙", namePattern),
                                        row("", meta), row("워터마크", mark), row("", NSStackView(views: [markSize, markCorner])),
                                        progress, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        progress.widthAnchor.constraint(equalToConstant: 420).isActive = true
        buttons.widthAnchor.constraint(equalToConstant: 420).isActive = true
        window?.contentView = stack
    }

    @objc private func qualityChanged() {
        qualityLabel.stringValue = "\(Int(quality.doubleValue))"
        let lossy = [ExportRecipe.Format.jpeg, .heic].contains(ExportRecipe.Format.allCases[format.indexOfSelectedItem])
        quality.isEnabled = lossy
    }

    @objc private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "이 폴더에 내보내기"
        guard p.runModal() == .OK, let url = p.url else { return }
        recipe.folder = url.path
        folderLabel.stringValue = url.path
    }

    @objc func close(_ sender: Any?) {
        guard let w = window else { return }
        w.sheetParent?.endSheet(w)
    }

    func setJobs(_ jobs: [(PhotoItem, RawDocument?)]) { self.jobs = jobs }

    private func readRecipe() {
        recipe.format = ExportRecipe.Format.allCases[format.indexOfSelectedItem]
        recipe.space = ExportRecipe.Space.allCases[space.indexOfSelectedItem]
        recipe.longSide = Self.sizes[size.indexOfSelectedItem]
        recipe.sharpen = sharpen.indexOfSelectedItem
        recipe.quality = quality.doubleValue / 100
        recipe.suffix = suffix.stringValue
        recipe.keepMetadata = meta.state == .on
        recipe.watermark = mark.stringValue
        recipe.watermarkSize = markSize.selectedItem?.representedObject as? Double ?? 2.5
        recipe.watermarkCorner = markCorner.indexOfSelectedItem
        recipe.namePattern = namePattern.stringValue.isEmpty ? nil : namePattern.stringValue
        recipe.save()
    }

    private func rebuildRecipeMenus() {
        recipePopup.removeAllItems()
        recipePopup.addItem(withTitle: "레시피")
        for r in ExportRecipe.library {
            let it = NSMenuItem(title: "불러오기: \(r.name ?? "이름 없음")", action: #selector(loadRecipe(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = r.name
            recipePopup.menu?.addItem(it)
        }
        recipePopup.menu?.addItem(.separator())
        let save = NSMenuItem(title: "지금 설정을 레시피로 저장…", action: #selector(saveRecipe), keyEquivalent: "")
        save.target = self
        recipePopup.menu?.addItem(save)
        let del = NSMenuItem(title: "저장한 레시피 모두 지우기", action: #selector(clearRecipes), keyEquivalent: "")
        del.target = self
        recipePopup.menu?.addItem(del)
        alsoPopup.removeAllItems()
        alsoPopup.addItem(withTitle: also.isEmpty ? "함께 쓸 레시피 없음" : "함께 쓸 레시피 \(also.count)개")
        for r in ExportRecipe.library {
            let it = NSMenuItem(title: r.name ?? "이름 없음", action: #selector(toggleAlso(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = r.name
            it.state = also.contains(r.name ?? "") ? .on : .off
            alsoPopup.menu?.addItem(it)
        }
        alsoPopup.isEnabled = !ExportRecipe.library.isEmpty
    }

    @objc private func loadRecipe(_ item: NSMenuItem) {
        guard let r = ExportRecipe.library.first(where: { $0.name == item.representedObject as? String }) else { return }
        recipe = r
        format.selectItem(at: ExportRecipe.Format.allCases.firstIndex(of: r.format) ?? 0)
        space.selectItem(at: ExportRecipe.Space.allCases.firstIndex(of: r.space) ?? 0)
        size.selectItem(at: Self.sizes.firstIndex(of: r.longSide) ?? 0)
        sharpen.selectItem(at: r.sharpen)
        quality.doubleValue = r.quality * 100
        folderLabel.stringValue = r.folder
        suffix.stringValue = r.suffix
        namePattern.stringValue = r.namePattern ?? ""
        meta.state = r.keepMetadata ? .on : .off
        mark.stringValue = r.watermark
        qualityChanged()
    }

    @objc private func saveRecipe() {
        readRecipe()
        let a = NSAlert()
        a.messageText = "레시피 이름"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        f.stringValue = "\(recipe.format.title) \(recipe.longSide == 0 ? "원본" : "\(recipe.longSide)px")"
        a.accessoryView = f
        a.addButton(withTitle: "저장"); a.addButton(withTitle: "취소").keyEquivalent = "\u{1b}"
        guard a.runModal() == .alertFirstButtonReturn, !f.stringValue.isEmpty else { return }
        var r = recipe
        r.name = f.stringValue
        var lib = ExportRecipe.library.filter { $0.name != r.name }
        lib.append(r)
        ExportRecipe.library = lib
        rebuildRecipeMenus()
    }

    @objc private func clearRecipes() { ExportRecipe.library = []; also = []; rebuildRecipeMenus() }

    @objc private func toggleAlso(_ item: NSMenuItem) {
        guard let n = item.representedObject as? String else { return }
        if also.contains(n) { also.remove(n) } else { also.insert(n) }
        UserDefaults.standard.set(Array(also), forKey: "exportAlso")
        rebuildRecipeMenus()
    }

    @objc func start() {
        readRecipe()
        // Current settings + recipes chosen to write along, in turn (several formats at once)
        var queue = [recipe] + ExportRecipe.library.filter { also.contains($0.name ?? "") && $0 != recipe }
        var all: [URL] = []
        func next() {
            guard !queue.isEmpty else { finish(all); return }
            let r = queue.removeFirst()
            if queue.count > 0 || all.count > 0 { status.stringValue = "레시피: \(r.name ?? r.format.title)" }
            run(r) { urls in all += urls; next() }
        }
        next()
    }

    private func finish(_ urls: [URL]) {
        status.stringValue = "\(urls.count)장 내보냄"
        go.title = "Finder에서 보기"
        go.action = #selector(reveal)
        done = urls
        onDone?(urls)
    }

    private var done: [URL] = []
    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting(done) }

    /// Exports in turn in the background. Already-open documents are used as is; others are opened with their saved adjustments.
    func run(_ r: ExportRecipe, completion: @escaping ([URL]) -> Void) {
        let jobs = self.jobs, lib = library
        JobCenter.shared.add("export", title: "내보내기", count: jobs.count)
        progress.isHidden = false
        progress.minValue = 0; progress.maxValue = Double(jobs.count); progress.doubleValue = 0
        go.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var urls: [URL] = [], errors: [String] = []
            for (i, (item, open)) in jobs.enumerated() {
                DispatchQueue.main.async { self?.status.stringValue = "\(i + 1)/\(jobs.count) \(item.name)" }
                defer { JobCenter.shared.step("export") }
                if item.offline { errors.append("\(item.name): 원본이 오프라인"); continue }
                do {
                    let doc: RawDocument
                    if let open { doc = open } else {
                        doc = try RawDocument(url: item.url)
                        if let s = lib?.loadSettings(for: item.url, over: doc.asShot) { doc.settings = s; doc.applyImportedWB() }
                    }
                    var name = item.variant > 0 ? item.name.replacingOccurrences(of: " (변형 ", with: "_v").replacingOccurrences(of: ")", with: "") : item.name
                    if let p = r.namePattern, !p.isEmpty {
                        var date: Date?
                        DispatchQueue.main.sync {
                            try? lib?.catalog.db.query("SELECT capture_date FROM images WHERE id = ?", [item.id]) { d in date = d.optDouble(0).map { Date(timeIntervalSince1970: $0) } }
                        }
                        name = MainWindowController.renamed(p, item: item, index: i + 1, date: date, camera: doc.info.camera) + "." + item.url.pathExtension
                    }
                    let run = { urls.append(try Exporter.export(doc, recipe: r, name: name)) }
                    // The open document is shared with the view, so write it on the main thread (it touches the caches too).
                    if open != nil { try DispatchQueue.main.sync(execute: run) } else { try run() }
                } catch {
                    errors.append(error.localizedDescription)
                }
                DispatchQueue.main.async { self?.progress.doubleValue = Double(i + 1) }
            }
            DispatchQueue.main.async {
                self?.go.isEnabled = true
                if !errors.isEmpty { self?.status.stringValue = errors.prefix(3).joined(separator: " · ") }
                completion(urls)
            }
        }
    }
}
