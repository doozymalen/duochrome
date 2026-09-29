import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Save for Web: changing format, quality, or size immediately shows the compressed result and file size.
/// Source on the left, compressed result on the right, side by side at the same spot at 100%.
final class WebExportWindow: NSWindowController {
    struct Format { let title: String; let type: UTType; let lossy: Bool }
    static var formats: [Format] {
        var f = [Format(title: "JPEG", type: .jpeg, lossy: true), Format(title: "HEIC", type: .heic, lossy: true),
                 Format(title: "PNG", type: .png, lossy: false)]
        let can = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        if let webp = UTType("org.webmproject.webp"), can.contains(webp.identifier) { f.insert(Format(title: "WebP", type: webp, lossy: true), at: 1) }
        if let avif = UTType("public.avif"), can.contains(avif.identifier) { f.append(Format(title: "AVIF", type: avif, lossy: true)) }
        return f
    }
    static let sizes = [0, 3840, 2560, 2048, 1600, 1200, 1080, 800]

    private let doc: RawDocument
    private let original = NSImageView(), compressed = NSImageView()
    private let format = NSPopUpButton(), size = NSPopUpButton()
    private let quality = NSSlider(value: 80, minValue: 10, maxValue: 100, target: nil, action: nil)
    private let info = NSTextField(labelWithString: "")
    private var base: (Int, CGImage)?
    private(set) var encoded = Data()
    private var pending: DispatchWorkItem?

    init(doc: RawDocument) {
        self.doc = doc
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "웹용 내보내기"
        super.init(window: w)
        build()
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        for f in Self.formats { format.addItem(withTitle: f.title) }
        for s in Self.sizes { size.addItem(withTitle: s == 0 ? "원본 크기" : "긴 변 \(s)px") }
        size.selectItem(at: 4)
        for c in [format, size] as [NSControl] { c.target = self; c.action = #selector(changed) }
        quality.target = self; quality.action = #selector(changed); quality.isContinuous = true
        quality.widthAnchor.constraint(equalToConstant: 180).isActive = true
        info.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        for iv in [original, compressed] {
            iv.imageScaling = .scaleNone
            iv.wantsLayer = true
            iv.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        }
        let l1 = NSTextField(labelWithString: "원본 (100%)"), l2 = NSTextField(labelWithString: "압축 결과 (100%)")
        let left = NSStackView(views: [l1, original]), right = NSStackView(views: [l2, compressed])
        for s in [left, right] { s.orientation = .vertical; s.alignment = .leading }
        let pics = NSStackView(views: [left, right])
        pics.distribution = .fillEqually
        let save = NSButton(title: "저장…", target: self, action: #selector(saveTapped)); save.keyEquivalent = "\r"
        let close = NSButton(title: "닫기", target: self, action: #selector(closeTapped)); close.keyEquivalent = "\u{1b}"
        let bar = NSStackView(views: [NSTextField(labelWithString: "형식"), format, NSTextField(labelWithString: "품질"), quality,
                                      NSTextField(labelWithString: "크기"), size, info, NSView(), close, save])
        let root = NSStackView(views: [pics, bar])
        root.orientation = .vertical
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.spacing = 12
        pics.heightAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true
        for iv in [original, compressed] { iv.heightAnchor.constraint(greaterThanOrEqualToConstant: 480).isActive = true }
        window?.contentView = root
    }

    private func baseImage() -> CGImage? {
        let long = Self.sizes[size.indexOfSelectedItem]
        if let b = base, b.0 == long { return b.1 }
        var img = doc.withFullResolution { doc.image(scale: 1) }
        let e = img.extent
        if long > 0, max(e.width, e.height) > CGFloat(long) {
            let k = CGFloat(long) / max(e.width, e.height)
            img = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1])
        }
        let r = img.extent.integral
        img = img.cropped(to: r).transformed(by: .init(translationX: -r.minX, y: -r.minY))
            .applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 0.6, kCIInputIntensityKey: 0.3])
        guard let cg = Render.context.createCGImage(img, from: CGRect(origin: .zero, size: r.size), format: .RGBA8,
                                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        let noAlpha = Exporter.dropAlpha(cg) ?? cg
        base = (long, noAlpha)
        return noAlpha
    }

    /// Encoding (sRGB without alpha, no metadata — light for the web)
    static func encode(_ cg: CGImage, type: UTType, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    @objc private func changed() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.update() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    private func update() {
        guard let cg = baseImage() else { return }
        let f = Self.formats[format.indexOfSelectedItem]
        quality.isEnabled = f.lossy
        guard let data = Self.encode(cg, type: f.type, quality: quality.doubleValue / 100),
              let src = CGImageSourceCreateWithData(data as CFData, nil), let back = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            info.stringValue = "이 형식으로 쓸 수 없습니다"; return
        }
        encoded = data
        // center 100% tile
        let side = 460
        let cx = max(0, cg.width / 2 - side / 2), cy = max(0, cg.height / 2 - side / 2)
        let rect = CGRect(x: cx, y: cy, width: min(side, cg.width), height: min(side, cg.height))
        if let a = cg.cropping(to: rect), let b = back.cropping(to: rect) {
            original.image = NSImage(cgImage: a, size: NSSize(width: a.width, height: a.height))
            compressed.image = NSImage(cgImage: b, size: NSSize(width: b.width, height: b.height))
        }
        let kb = Double(data.count) / 1024
        info.stringValue = String(format: "%d×%d · %@", cg.width, cg.height, kb > 1024 ? String(format: "%.2f MB", kb / 1024) : String(format: "%.0f KB", kb))
    }

    @objc private func saveTapped() {
        let f = Self.formats[format.indexOfSelectedItem]
        let p = NSSavePanel()
        p.nameFieldStringValue = doc.url.deletingPathExtension().lastPathComponent + "-web." + (f.type.preferredFilenameExtension ?? "jpg")
        p.allowedContentTypes = [f.type]
        guard let w = window else { return }
        p.beginSheetModal(for: w) { [weak self] r in
            guard r == .OK, let url = p.url, let self else { return }
            try? self.encoded.write(to: url)
        }
    }

    @objc private func closeTapped() { window?.sheetParent?.endSheet(window!); window?.close() }
}

extension MainWindowController {
    @objc func exportForWeb(_ sender: Any?) {
        guard let doc = photo, let window else { NSSound.beep(); return }
        let w = WebExportWindow(doc: doc)
        webExport = w
        window.beginSheet(w.window!)
    }

    var webExport: WebExportWindow? {
        get { objc_getAssociatedObject(self, &webExportKey) as? WebExportWindow }
        set { objc_setAssociatedObject(self, &webExportKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}
private var webExportKey = 0
