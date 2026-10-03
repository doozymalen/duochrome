import AppKit
import CoreImage

/// `.duochrome` document: source RAW path + all adjustments (including retouch spots and layers) + preview in one package (folder).
/// The RAW itself isn't included (size). If the source moved, asks to locate it on open.
///
/// Layout: `name.duochrome/document.json`, `name.duochrome/preview.jpg`
enum DuochromeDocument {
    static let ext = "duochrome"
    static let version = 1

    struct Contents {
        var source: URL
        var sourceSize: Int64?
        var settings: [String: Any]
    }

    static func save(_ doc: RawDocument, to url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        let settingsData = try JSONEncoder().encode(doc.settings)
        let settings = try JSONSerialization.jsonObject(with: settingsData)
        let size = (try? fm.attributesOfItem(atPath: doc.url.path)[.size] as? NSNumber)?.int64Value
        let json: [String: Any] = [
            "format": "duochrome", "version": version,
            "source": doc.url.path, "sourceName": doc.url.lastPathComponent,
            "sourceSize": size ?? 0,
            "savedAt": ISO8601DateFormatter().string(from: Date()),
            "settings": settings,
        ]
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            .write(to: url.appendingPathComponent("document.json"))
        // Image layer pictures are included too (images/filename).
        let files = Set(doc.settings.layers.compactMap { $0.image?.file })
        if !files.isEmpty {
            let dir = url.appendingPathComponent("images", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in files where fm.fileExists(atPath: LayerImageStore.url(f).path) {
                try fm.copyItem(at: LayerImageStore.url(f), to: dir.appendingPathComponent(f))
            }
        }
        // Preview: 1600 px long side JPEG
        let img = doc.image(scale: 1.0 / 4)
        let k = min(1, 1600 / max(img.extent.width, img.extent.height))
        let small = img.transformed(by: .init(scaleX: k, y: k))
        try Render.context.writeJPEGRepresentation(of: small, to: url.appendingPathComponent("preview.jpg"),
                                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                   options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85])
    }

    static func read(_ url: URL) throws -> Contents {
        let data = try Data(contentsOf: url.appendingPathComponent("document.json"))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["format"] as? String == "duochrome", let path = json["source"] as? String,
              let settings = json["settings"] as? [String: Any] else {
            throw Exporter.Failure(message: "\(url.lastPathComponent)은 Duochrome 문서가 아닙니다")
        }
        // Restore bundled layer images to the image folder (keep existing ones).
        let dir = url.appendingPathComponent("images", isDirectory: true)
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        where !FileManager.default.fileExists(atPath: LayerImageStore.url(f).path) {
            try? FileManager.default.copyItem(at: dir.appendingPathComponent(f), to: LayerImageStore.url(f))
        }
        return Contents(source: URL(fileURLWithPath: path), sourceSize: (json["sourceSize"] as? NSNumber)?.int64Value,
                        settings: settings)
    }
}

extension MainWindowController {
    @objc func saveDocument(_ sender: Any?) {
        guard let doc = photo, let window else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (doc.url.lastPathComponent as NSString).deletingPathExtension + ".duochrome"
        panel.allowedContentTypes = []
        panel.message = "원본 RAW 경로와 모든 조정(리터칭·레이어 포함), 미리보기를 한 파일에 담습니다. RAW 파일은 넣지 않습니다."
        panel.beginSheetModal(for: window) { r in
            guard r == .OK, var url = panel.url else { return }
            if url.pathExtension != DuochromeDocument.ext { url.appendPathExtension(DuochromeDocument.ext) }
            do { try DuochromeDocument.save(doc, to: url) } catch { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }

    /// Opens a document: registers the source in the catalog, writes the document's adjustments to it, and opens edit mode.
    func openDuochromeDocument(_ url: URL) {
        guard let window else { return }
        do {
            var c = try DuochromeDocument.read(url)
            if !FileManager.default.fileExists(atPath: c.source.path) {
                let a = NSAlert()
                a.messageText = "원본 파일을 찾을 수 없습니다"
                a.informativeText = "\(c.source.path)\n원본을 옮겼다면 찾아 주세요."
                a.addButton(withTitle: "찾기…")
                a.addButton(withTitle: "취소").keyEquivalent = "\u{1b}"
                guard a.runModal() == .alertFirstButtonReturn else { return }
                let p = NSOpenPanel()
                p.nameFieldStringValue = c.source.lastPathComponent
                guard p.runModal() == .OK, let found = p.url else { return }
                c.source = found
            }
            if library.hasSettings(for: c.source) {
                let a = NSAlert()
                a.messageText = "이 사진에는 이미 조정이 있습니다"
                a.informativeText = "문서의 조정으로 바꿀까요? (지금 조정은 작업 내역에서 되돌릴 수 없습니다)"
                a.addButton(withTitle: "문서 조정으로 바꾸기")
                a.addButton(withTitle: "지금 조정 그대로 열기")
                if a.runModal() == .alertFirstButtonReturn { library.saveRawSettings(c.settings, for: c.source) }
            } else {
                library.saveRawSettings(c.settings, for: c.source)
            }
            photoItem = nil
            openFileOrFolder(c.source)
            // If the folder is already shown the list isn't reloaded, so fix the adjusted badge directly.
            if let item = library.items.first(where: { $0.url.standardizedFileURL == c.source.standardizedFileURL }) {
                item.edited = library.hasSettings(for: c.source)
                item.thumbnail = nil
                refreshItem(item)
            }
            setMode(.edit)
        } catch {
            NSAlert(error: error).beginSheetModal(for: window)
        }
    }
}
