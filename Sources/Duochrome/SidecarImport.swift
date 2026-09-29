import AppKit
import ImageIO

/// Session sidecar (.cos) and style (.costyle) import. Both are `<E K="key" V="value"/>` XML,
/// and key names match the catalog DB column names (Z + uppercase), so catalog import's conversion (CatalogImport.convert) is reused as is.
///
/// - Session: `folder/(settings folder)/Settings*/photo.CR3.cos`. `<AL>` (adjustments) overlays `<DL>` (defaults).
/// - Style: values inside `<SL>` → saved as a Duochrome style (JSON)
enum SidecarImport {
    /// Sidecar keys whose catalog column names differ
    static let renamed: [String: String] = [
        "HighlightRecoveryEx": "ZHIGHLIGHTRECOVERY", "Shadow": "ZLEVELSSHADOW", "Highlight": "ZLEVELSHIGHLIGHT",
        "Vignetting": "ZLENSVIGNETTING", "BwDarkHue": "ZBWDARKTONEHUE", "BwDarkSaturation": "ZBWDARKTONESATURATION",
        "BwLightHue": "ZBWLIGHTTONEHUE", "BwLightSaturation": "ZBWLIGHTTONESATURATION",
    ]

    struct Parsed {
        var values: [String: String] = [:]
        var rating: Int?
        var color: Int?
        var name: String?
    }

    /// Collects `<E K V>` from XML. In session files AL overrides DL (later values win).
    static func parse(_ data: Data) -> Parsed {
        final class Collector: NSObject, XMLParserDelegate {
            var p = Parsed()
            var depthInLayers = 0   // values inside local layers (LDS) aren't global
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                        attributes a: [String: String] = [:]) {
                if name == "LDS" || name == "LD" { depthInLayers += 1; return }
                guard name == "E", depthInLayers == 0, let k = a["K"], let v = a["V"] else { return }
                switch k {
                case "Basic_Rating": p.rating = Int(v)
                case "Color_Tag_Index": p.color = Int(v)
                case "Name": p.name = v
                default: p.values[k] = v
                }
            }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                if name == "LDS" || name == "LD" { depthInLayers -= 1 }
            }
        }
        let c = Collector()
        let x = XMLParser(data: data)
        x.delegate = c
        x.parse()
        return c.p
    }

    /// Sidecar values → dictionary accepted by CatalogImport.convert (column name → number or text)
    static func columns(_ values: [String: String]) -> [String: Any] {
        var d: [String: Any] = [:]
        for (k, v) in values {
            let col = renamed[k] ?? "Z" + k.uppercased()
            d[col] = Double(v) ?? v
        }
        return d
    }

    /// One photo's .cos → Duochrome settings fragment
    static func settings(from cos: Parsed, image: URL) -> [String: Any] {
        var orientation: Int?
        if let src = CGImageSourceCreateWithURL(image as CFURL, nil),
           let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            orientation = p[kCGImagePropertyOrientation] as? Int
        }
        return CatalogImport.convert(columns(cos.values), orientation: orientation)
    }

    struct Report {
        var found = 0, applied = 0, skippedExisting = 0, missing = 0, rated = 0
        var summary: String {
            "세션 설정 \(found)개: 조정 \(applied)장 옮김, 이미 조정한 사진 \(skippedExisting)장은 그대로, 원본 없음 \(missing)장, 별점·색 \(rated)장"
        }
    }

    /// Finds all `Settings*/*.cos` under a folder (a session folder or any folder below it)
    static func findSidecars(in folder: URL) -> [URL] {
        var out: [URL] = []
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        for case let u as URL in e {
            if u.pathExtension == "cos", u.deletingLastPathComponent().lastPathComponent.hasPrefix("Settings") {
                out.append(u)
            }
            if e.level > 6 { e.skipDescendants() }
        }
        return out
    }

    /// Sidecar → source photo path (the folder containing the settings folder + the name without .cos)
    static func image(for cos: URL) -> URL {
        cos.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(cos.deletingPathExtension().lastPathComponent)
    }

    static func importSession(_ folder: URL, catalog: Catalog, library: Library, overwrite: Bool) -> Report {
        var r = Report()
        let cars = findSidecars(in: folder)
        r.found = cars.count
        var folders = Set<URL>()
        for cos in cars {
            let img = image(for: cos)
            guard FileManager.default.fileExists(atPath: img.path), let data = try? Data(contentsOf: cos) else { r.missing += 1; continue }
            let p = parse(data)
            let folderURL = img.deletingLastPathComponent()
            if !folders.contains(folderURL) { _ = try? catalog.addFolder(folderURL); folders.insert(folderURL) }
            if !overwrite, library.hasSettings(for: img) { r.skippedExisting += 1 } else {
                let s = settings(from: p, image: img)
                if !s.isEmpty { library.saveRawSettings(s, for: img); r.applied += 1 }
            }
            if (p.rating ?? 0) > 0 || (p.color ?? 0) > 0 {
                var id: Int64?
                try? catalog.db.query("SELECT id FROM images WHERE path = ?", [img.path]) { id = $0.int(0) }
                if let id {
                    if let v = p.rating, v > 0 { try? catalog.setRating([id], v) }
                    if let v = p.color, v > 0 { try? catalog.setColor([id], v) }
                    r.rated += 1
                }
            }
        }
        return r
    }
}

extension MainWindowController {
    @objc func importSidecarImport(_ sender: Any?) {
        guard let window else { return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.message = "세션 폴더(또는 설정 폴더가 든 폴더)를 고르세요. 설정 파일(.cos)은 읽기만 합니다."
        p.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = p.url, let self else { return }
            let a = NSAlert()
            a.messageText = "이미 Duochrome에서 조정한 사진은 어떻게 할까요?"
            a.addButton(withTitle: "그대로 두기")
            a.addButton(withTitle: "가져온 값으로 바꾸기")
            let overwrite = a.runModal() == .alertSecondButtonReturn
            let rep = SidecarImport.importSession(url, catalog: self.library.catalog, library: self.library, overwrite: overwrite)
            self.openFolder(url)
            let done = NSAlert()
            done.messageText = "세션 보정값 가져오기"
            done.informativeText = rep.summary + "\n화이트 밸런스·크롭·키스톤·로컬 레이어는 아직 옮기지 않습니다."
            done.beginSheetModal(for: window)
        }
    }

    @objc func importStyleFiles(_ sender: Any?) {
        guard let window else { return }
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.message = "스타일(.costyle) 파일이나 스타일 폴더를 고르세요."
        p.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let self else { return }
            var files: [URL] = []
            for u in p.urls {
                var dir: ObjCBool = false
                FileManager.default.fileExists(atPath: u.path, isDirectory: &dir)
                if dir.boolValue, let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil) {
                    for case let f as URL in e where f.pathExtension == "costyle" { files.append(f) }
                } else if u.pathExtension == "costyle" { files.append(u) }
            }
            var n = 0
            for f in files {
                guard let d = try? Data(contentsOf: f) else { continue }
                let parsed = SidecarImport.parse(d)
                let dict = CatalogImport.convert(SidecarImport.columns(parsed.values), orientation: 1)
                guard !dict.isEmpty, let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { continue }
                let name = "가져옴 · " + (parsed.name ?? f.deletingPathExtension().lastPathComponent).replacingOccurrences(of: "/", with: "-")
                try? data.write(to: Self.stylesFolder.appendingPathComponent("\(name).json"))
                n += 1
            }
            let a = NSAlert()
            a.messageText = "스타일 \(n)개를 가져왔습니다"
            a.informativeText = "사진 → 스타일 메뉴에 \"가져옴 · 이름\"으로 들어 있습니다. 값은 옮기지만 결과가 원래 프로그램과 똑같이 보이지는 않습니다."
            a.beginSheetModal(for: window)
        }
    }

    @objc func importPresets(_ sender: Any?) {
        guard let window else { return }
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.allowedContentTypes = ["abr", "grd", "pat", "aco"].compactMap { .init(filenameExtension: $0) }
        p.message = "브러시(.abr)·그라디언트(.grd)·패턴(.pat)·견본(.aco)을 고르세요."
        p.beginSheetModal(for: window) { r in
            guard r == .OK else { return }
            var lines: [String] = []
            for u in p.urls {
                do { lines.append("\(u.lastPathComponent): " + (try PresetFiles.importFile(u))) } catch { lines.append("\(u.lastPathComponent): \(error.localizedDescription)") }
            }
            let a = NSAlert()
            a.messageText = "프리셋 가져오기"
            a.informativeText = lines.joined(separator: "\n") + "\n\n브러시는 마스크 붓의 붓 끝, 그라디언트는 그라디언트 맵·칠 레이어, 패턴은 칠 레이어, 견본은 색 고르기에서 씁니다."
            a.beginSheetModal(for: window)
        }
    }
}
