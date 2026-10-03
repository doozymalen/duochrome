import AppKit
import ImageIO

/// Photo management actions: pick/reject, keywords, IPTC metadata / XMP sidecars, variants, batch rename,
/// capture time fix, relink.
extension MainWindowController {
    // MARK: - Pick / reject

    func flag(_ f: Int) {
        let items = targetItems
        guard !items.isEmpty else { return }
        try? library.catalog.setFlag(items.map(\.id), f)
        items.forEach { $0.flag = f; refreshItem($0) }
        libraryMode.panel.show(libraryMode.grid.selectedItems, clipboard: batchClipboardName)
    }

    @objc func flagFromMenu(_ sender: NSMenuItem) { flag(sender.tag) }

    // MARK: - Keywords

    /// Several separated by commas, hierarchy with ">", e.g. "Travel, Places>Seoul>Jongno"
    func addKeywords(_ text: String, to items: [PhotoItem]? = nil) {
        let items = items ?? targetItems
        let paths = text.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !items.isEmpty, !paths.isEmpty else { NSSound.beep(); return }
        try? library.catalog.addKeywords(items.map(\.id), paths)
        reloadSources()
        libraryMode.panel.show(libraryMode.grid.selectedItems, clipboard: batchClipboardName)
    }

    func removeKeyword(_ id: Int64) {
        try? library.catalog.removeKeyword(targetItems.map(\.id), id)
        reloadSources()
        libraryMode.panel.show(libraryMode.grid.selectedItems, clipboard: batchClipboardName)
    }

    // MARK: - Variants

    /// Creates a variant for each selected photo, starting from the current adjustments (duplicate).
    @objc func makeVariant(_ sender: Any?) {
        let items = targetItems.filter { $0.id != 0 }
        guard !items.isEmpty else { NSSound.beep(); return }
        var made: [URL] = []
        for item in items {
            guard let v = try? library.catalog.addVariant(of: item.id) else { continue }
            if let raw = library.rawSettings(for: item.url), let dict = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
                library.saveRawSettings(dict, for: v)
            }
            made.append(v)
        }
        library.show(library.source)
        reloadAfterLibraryChange()
        if let last = made.last, let item = library.items.first(where: { $0.url == last }) {
            libraryMode.grid.mirror(item); browser.mirror(item)
            if mode != .library { show(item) }
        }
    }

    func reloadAfterLibraryChange() {
        browser.reload()
        libraryMode.grid.reload()
        tetherMode.strip.reload()
        reloadSources()
    }

    // MARK: - Batch rename

    /// Naming rule: {이름} original name, {날짜} capture date yyyyMMdd, {시각} HHmmss, {번호} 3-digit sequence, {번호4} 4-digit, {카메라}, {별점}
    static func renamed(_ pattern: String, item: PhotoItem, index: Int, date: Date?, camera: String) -> String {
        let f = DateFormatter()
        var s = pattern
        let base = (item.url.lastPathComponent as NSString).deletingPathExtension
        f.dateFormat = "yyyyMMdd"; let day = date.map(f.string(from:)) ?? "날짜없음"
        f.dateFormat = "HHmmss"; let time = date.map(f.string(from:)) ?? "000000"
        s = s.replacingOccurrences(of: "{이름}", with: base)
            .replacingOccurrences(of: "{날짜}", with: day).replacingOccurrences(of: "{시각}", with: time)
            .replacingOccurrences(of: "{번호4}", with: String(format: "%04d", index))
            .replacingOccurrences(of: "{번호}", with: String(format: "%03d", index))
            .replacingOccurrences(of: "{카메라}", with: camera.replacingOccurrences(of: " ", with: ""))
            .replacingOccurrences(of: "{별점}", with: "\(item.rating)")
        return s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    func captureDate(_ item: PhotoItem) -> Date? {
        var d: Double?
        try? library.catalog.db.query("SELECT capture_date FROM images WHERE id = ?", [item.id]) { d = $0.optDouble(0) }
        return d.map { Date(timeIntervalSince1970: $0) }
    }

    /// Renames files (source and same-named .xmp/.cos sidecars). Moves the catalog path and adjustment keys too.
    @discardableResult
    func renameFiles(_ items: [PhotoItem], pattern: String, start: Int = 1) -> (Int, [String]) {
        let fm = FileManager.default
        var n = 0, errors: [String] = []
        for (i, item) in items.enumerated() where item.variant == 0 && !item.offline {
            let src = URL(fileURLWithPath: item.url.path)
            var cam = ""
            try? library.catalog.db.query("SELECT camera FROM images WHERE id = ?", [item.id]) { cam = $0.text(0) ?? "" }
            let newBase = Self.renamed(pattern, item: item, index: start + i, date: captureDate(item), camera: cam)
            guard !newBase.isEmpty else { continue }
            let dst = src.deletingLastPathComponent().appendingPathComponent(newBase).appendingPathExtension(src.pathExtension)
            if dst == src { continue }
            guard !fm.fileExists(atPath: dst.path) else { errors.append("\(dst.lastPathComponent) 이미 있음"); continue }
            do {
                try fm.moveItem(at: src, to: dst)
                // sidecars
                for ext in ["xmp", "XMP"] {
                    let side = src.deletingPathExtension().appendingPathExtension(ext)
                    if fm.fileExists(atPath: side.path) { try? fm.moveItem(at: side, to: dst.deletingPathExtension().appendingPathExtension(ext)) }
                }
                try library.catalog.movePath(from: src, to: dst)
                n += 1
            } catch { errors.append("\(src.lastPathComponent): \(error.localizedDescription)") }
        }
        return (n, errors)
    }

    @objc func batchRename(_ sender: Any?) {
        let items = targetItems.filter { $0.variant == 0 }
        guard !items.isEmpty else { NSSound.beep(); return }
        let a = NSAlert()
        a.messageText = "\(items.count)장 이름 바꾸기"
        a.informativeText = "{이름} {날짜} {시각} {번호} {번호4} {카메라} {별점}을 쓸 수 있습니다. 같은 이름의 .xmp 사이드카도 같이 바꿉니다."
        let field = NSTextField(string: UserDefaults.standard.string(forKey: "renamePattern") ?? "{날짜}_{번호}")
        let startField = NSTextField(string: "1")
        let preview = NSTextField(labelWithString: "")
        preview.textColor = .secondaryLabelColor
        func update() {
            preview.stringValue = "예: " + Self.renamed(field.stringValue, item: items[0], index: Int(startField.stringValue) ?? 1,
                                                          date: captureDate(items[0]), camera: "EOSR5") + "." + items[0].url.pathExtension
        }
        update()
        let obs = NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification, object: nil, queue: .main) { _ in update() }
        defer { NotificationCenter.default.removeObserver(obs) }
        let st = NSStackView(views: [field, NSStackView(views: [NSTextField(labelWithString: "시작 번호"), startField]), preview])
        st.orientation = .vertical; st.alignment = .leading
        st.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        a.accessoryView = st
        a.addButton(withTitle: "바꾸기"); a.addButton(withTitle: "취소").keyEquivalent = "\u{1b}"
        guard a.runModal() == .alertFirstButtonReturn else { return }
        UserDefaults.standard.set(field.stringValue, forKey: "renamePattern")
        let (n, errors) = renameFiles(items, pattern: field.stringValue, start: Int(startField.stringValue) ?? 1)
        library.show(library.source)
        reloadAfterLibraryChange()
        if !errors.isEmpty {
            let e = NSAlert(); e.messageText = "\(n)장 바꿈, \(errors.count)장 못 바꿈"; e.informativeText = errors.prefix(8).joined(separator: "\n"); e.runModal()
        }
    }

    // MARK: - Capture time fix

    func shiftCaptureTime(_ items: [PhotoItem], by seconds: Double) {
        try? library.catalog.db.transaction {
            for it in items {
                try library.catalog.db.run("UPDATE images SET capture_date = COALESCE(capture_date, imported_at) + ? WHERE id = ?", [seconds, it.id])
                try library.catalog.setMetadata([it.id], "timeShift", String(seconds))
            }
        }
    }

    @objc func adjustCaptureTime(_ sender: Any?) {
        let items = targetItems
        guard !items.isEmpty else { NSSound.beep(); return }
        let a = NSAlert()
        a.messageText = "촬영 시각 고치기 (\(items.count)장)"
        a.informativeText = "카메라 시계가 틀렸을 때: 모든 사진을 같은 만큼 옮깁니다. 원본 파일은 그대로이고, XMP 사이드카를 쓰면 고친 시각이 들어갑니다."
        let h = NSTextField(string: "0"), m = NSTextField(string: "0"), d = NSTextField(string: "0")
        for f in [d, h, m] { f.widthAnchor.constraint(equalToConstant: 60).isActive = true }
        let st = NSStackView(views: [NSTextField(labelWithString: "일"), d, NSTextField(labelWithString: "시간"), h, NSTextField(labelWithString: "분"), m])
        st.frame = NSRect(x: 0, y: 0, width: 330, height: 24)
        a.accessoryView = st
        a.addButton(withTitle: "옮기기"); a.addButton(withTitle: "취소").keyEquivalent = "\u{1b}"
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let secs = (Double(d.stringValue) ?? 0) * 86400 + (Double(h.stringValue) ?? 0) * 3600 + (Double(m.stringValue) ?? 0) * 60
        shiftCaptureTime(items, by: secs)
        library.show(library.source)
        reloadAfterLibraryChange()
    }

    // MARK: - XMP sidecars

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// XMP sidecar text (standard XMP/IPTC): rating, color label, pick/reject, keywords (with hierarchy), IPTC core, capture time
    func xmp(for item: PhotoItem) -> String { Self.xmp(for: item, catalog: library.catalog) }

    static func captureDate(_ item: PhotoItem, _ cat: Catalog) -> Date? {
        var d: Double?
        try? cat.db.query("SELECT capture_date FROM images WHERE id = ?", [item.id]) { d = $0.optDouble(0) }
        return d.map { Date(timeIntervalSince1970: $0) }
    }

    static func xmp(for item: PhotoItem, catalog cat: Catalog) -> String {
        let meta = cat.metadata(item.id)
        let kws = cat.keywords(of: item.id).map(\.1)
        let leaves = Array(Set(kws.map { $0.split(separator: ">").last.map(String.init) ?? $0 })).sorted()
        let label = ["", "Red", "Orange", "Yellow", "Green", "Blue", "Pink", "Purple"][min(max(item.color, 0), 7)]
        func alt(_ tag: String, _ v: String?) -> String {
            guard let v, !v.isEmpty else { return "" }
            return "   <\(tag)><rdf:Alt><rdf:li xml:lang=\"x-default\">\(Self.xmlEscape(v))</rdf:li></rdf:Alt></\(tag)>\n"
        }
        func bag(_ tag: String, _ vs: [String], seq: Bool = false) -> String {
            guard !vs.isEmpty else { return "" }
            let k = seq ? "rdf:Seq" : "rdf:Bag"
            return "   <\(tag)><\(k)>" + vs.map { "<rdf:li>\(Self.xmlEscape($0))</rdf:li>" }.joined() + "</\(k)></\(tag)>\n"
        }
        var date = ""
        if let d = captureDate(item, cat) {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; f.timeZone = .current
            date = "   exif:DateTimeOriginal=\"\(f.string(from: d))\"\n   photoshop:DateCreated=\"\(f.string(from: d))\"\n"
        }
        var attrs = "   xmp:Rating=\"\(item.flag == -1 ? -1 : item.rating)\"\n   xmp:CreatorTool=\"Duochrome\"\n"
        if !label.isEmpty { attrs += "   xmp:Label=\"\(label)\"\n" }
        if item.flag == 1 { attrs += "   xmpDM:pick=\"1\"\n" }
        for (k, tag) in [("city", "photoshop:City"), ("country", "photoshop:Country"), ("location", "Iptc4xmpCore:Location")] {
            if let v = meta[k], !v.isEmpty { attrs += "   \(tag)=\"\(Self.xmlEscape(v))\"\n" }
        }
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Duochrome">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
           xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/"
           xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/" xmlns:exif="http://ns.adobe.com/exif/1.0/"
           xmlns:lr="http://ns.adobe.com/lightroom/1.0/" xmlns:xmpDM="http://ns.adobe.com/xmp/1.0/DynamicMedia/"
           xmlns:Iptc4xmpCore="http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/" xmlns:xmpRights="http://ns.adobe.com/xap/1.0/rights/"
        \(attrs)\(date)   >
        \(alt("dc:title", meta["title"]))\(alt("dc:description", meta["caption"]))\(alt("dc:rights", meta["copyright"]))\(bag("dc:creator", meta["creator"].map { [$0] } ?? [], seq: true))\(bag("dc:subject", leaves))\(bag("lr:hierarchicalSubject", kws.map { $0.replacingOccurrences(of: ">", with: "|") }))  </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    static func sidecarURL(_ item: PhotoItem) -> URL {
        let base = URL(fileURLWithPath: item.url.path).deletingPathExtension()
        return item.variant > 0 ? URL(fileURLWithPath: base.path + "_v\(item.variant)").appendingPathExtension("xmp") : base.appendingPathExtension("xmp")
    }

    @objc func writeXMPSidecars(_ sender: Any?) {
        let items = targetItems.filter { !$0.offline }
        guard !items.isEmpty else { NSSound.beep(); return }
        var n = 0
        for it in items { if (try? xmp(for: it).write(to: Self.sidecarURL(it), atomically: true, encoding: .utf8)) != nil { n += 1 } }
        window?.subtitle = "XMP 사이드카 \(n)개 씀"
    }

    /// Reads XMP sidecars: rating, label, keywords, IPTC core into the catalog (replaced with sidecar values, not only filling blanks)
    func readXMP(_ url: URL, into item: PhotoItem) -> Bool { Self.readXMP(url, into: item, library: library) }

    static func readXMP(_ url: URL, into item: PhotoItem, library: Library) -> Bool {
        guard let d = try? Data(contentsOf: url), let doc = try? XMLDocument(data: d) else { return false }
        func attr(_ name: String) -> String? {
            (try? doc.nodes(forXPath: "//*[local-name()='Description']/@*[name()='\(name)']"))?.first?.stringValue
                ?? (try? doc.nodes(forXPath: "//*[name()='\(name)']"))?.first?.stringValue
        }
        func list(_ name: String) -> [String] {
            ((try? doc.nodes(forXPath: "//*[name()='\(name)']//*[local-name()='li']")) ?? []).compactMap { $0.stringValue }
        }
        let cat = library.catalog
        if let r = attr("xmp:Rating").flatMap(Int.init) {
            if r < 0 { try? cat.setFlag([item.id], -1); item.flag = -1 } else { library.setRating([item], min(r, 5)) }
        }
        if let l = attr("xmp:Label"), let i = ["", "Red", "Orange", "Yellow", "Green", "Blue", "Pink", "Purple"].firstIndex(of: l) {
            library.setColor([item], i)
        }
        let hier = list("lr:hierarchicalSubject").map { $0.replacingOccurrences(of: "|", with: ">") }
        let kws = hier.isEmpty ? list("dc:subject") : hier
        if !kws.isEmpty { try? cat.addKeywords([item.id], kws) }
        for (key, name) in [("title", "dc:title"), ("caption", "dc:description"), ("copyright", "dc:rights"), ("creator", "dc:creator"),
                            ("city", "photoshop:City"), ("country", "photoshop:Country"), ("location", "Iptc4xmpCore:Location")] {
            if let v = list(name).first ?? attr(name), !v.isEmpty { try? cat.setMetadata([item.id], key, v) }
        }
        return true
    }

    @objc func readXMPSidecars(_ sender: Any?) {
        var n = 0
        for it in targetItems where FileManager.default.fileExists(atPath: Self.sidecarURL(it).path) {
            if readXMP(Self.sidecarURL(it), into: it) { n += 1; refreshItem(it) }
        }
        reloadSources()
        libraryMode.panel.show(libraryMode.grid.selectedItems, clipboard: batchClipboardName)
        window?.subtitle = "XMP 사이드카 \(n)개 읽음"
    }

    func setMetadata(_ key: String, _ value: String) {
        try? library.catalog.setMetadata(targetItems.map(\.id), key, value)
    }

    // MARK: - Compare view

    @objc func toggleCompare(_ sender: Any?) {
        if mode != .library { setMode(.library) }
        let lm = libraryMode
        if lm.isComparing { lm.showCompare(nil, library: library); return }
        let items = lm.grid.selectedItems
        guard items.count >= 2 else { NSSound.beep(); return }
        lm.showCompare(items, library: library)
    }

    // MARK: - Relink (offline photos)

    /// Finds files with the same name and size as offline photos in a folder (recursively) and moves the paths
    @discardableResult
    func relink(_ items: [PhotoItem], searchIn folder: URL) -> Int {
        var byName: [String: [URL]] = [:]
        if let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
            for case let u as URL in e where Library.supported.contains(u.pathExtension.lowercased()) {
                byName[u.lastPathComponent.lowercased(), default: []].append(u)
            }
        }
        var n = 0
        for it in items where it.variant == 0 {
            guard let found = byName[it.url.lastPathComponent.lowercased()]?.first else { continue }
            if (try? library.catalog.movePath(from: URL(fileURLWithPath: it.url.path), to: found)) != nil { n += 1 }
        }
        return n
    }

    @objc func relinkOffline(_ sender: Any?) {
        let items = (mode == .library ? libraryMode.grid.selectedItems : library.items).filter(\.offline)
        guard !items.isEmpty, let window else { NSSound.beep(); return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        p.message = "오프라인 사진 \(items.count)장을 찾을 폴더를 고르세요 (하위 폴더까지 같은 이름을 찾습니다)."
        p.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = p.url, let self else { return }
            let n = self.relink(items, searchIn: url)
            self.library.show(self.library.source)
            self.reloadAfterLibraryChange()
            let a = NSAlert(); a.messageText = "\(items.count)장 가운데 \(n)장을 다시 이었습니다"; a.beginSheetModal(for: window)
        }
    }
}
