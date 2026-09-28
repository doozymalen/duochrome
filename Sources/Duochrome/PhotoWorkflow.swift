import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Accelerate
import simd

// MARK: - 불러오기 (복사·이동·제자리, 백업, 이름 규칙, 날짜 폴더, 스타일·키워드)

enum PhotoImporter {
    struct Options {
        enum Mode: Int { case inPlace, copy, move }
        var source: URL
        var mode: Mode = .inPlace
        var destination: URL?
        var backup: URL?
        /// 비었으면 원래 이름. {이름} {날짜} {시각} {번호} {카메라}
        var namePattern = ""
        /// 날짜별 하위 폴더 (yyyy-MM-dd)
        var dateFolders = false
        var includeSubfolders = true
        var style: String?
        var keywords = ""
        var readXMP = true
    }

    struct Result { var imported: [URL] = []; var skipped = 0; var errors: [String] = [] }

    static func captureDate(_ url: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let d = exif[kCGImagePropertyExifDateTimeOriginal] as? String else {
            return (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        }
        let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: d)
    }

    static func files(in folder: URL, recursive: Bool) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        if recursive, let e = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let u as URL in e where Library.supported.contains(u.pathExtension.lowercased()) {
                out.append(u)
            }
        } else {
            out = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .filter { Library.supported.contains($0.pathExtension.lowercased()) }
        }
        return out.sorted { $0.path < $1.path }
    }

    static func run(_ o: Options, catalog: Catalog, progress: ((String) -> Void)? = nil) -> Result {
        let fm = FileManager.default
        var r = Result()
        let list = files(in: o.source, recursive: o.includeSubfolders)
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        for (i, src) in list.enumerated() {
            progress?("\(i + 1)/\(list.count) \(src.lastPathComponent)")
            var dst = src
            if o.mode != .inPlace, let dest = o.destination {
                let date = captureDate(src)
                var dir = dest
                if o.dateFolders { dir = dir.appendingPathComponent(date.map(df.string(from:)) ?? "날짜 없음", isDirectory: true) }
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                var base = src.deletingPathExtension().lastPathComponent
                if !o.namePattern.isEmpty {
                    let item = PhotoItem(url: src)
                    base = MainWindowController.renamed(o.namePattern, item: item, index: i + 1, date: date, camera: ShotInfo(url: src).camera)
                }
                dst = dir.appendingPathComponent(base).appendingPathExtension(src.pathExtension)
                if fm.fileExists(atPath: dst.path) { r.skipped += 1; continue }
                do {
                    if o.mode == .move { try fm.moveItem(at: src, to: dst) } else { try fm.copyItem(at: src, to: dst) }
                    // 사이드카도 같이
                    let side = src.deletingPathExtension().appendingPathExtension("xmp")
                    if fm.fileExists(atPath: side.path) {
                        let sd = dst.deletingPathExtension().appendingPathExtension("xmp")
                        if o.mode == .move { try? fm.moveItem(at: side, to: sd) } else { try? fm.copyItem(at: side, to: sd) }
                    }
                } catch { r.errors.append("\(src.lastPathComponent): \(error.localizedDescription)"); continue }
            }
            if let b = o.backup {
                var bdir = b
                if o.dateFolders, let d = captureDate(dst) { bdir = bdir.appendingPathComponent(df.string(from: d), isDirectory: true) }
                try? fm.createDirectory(at: bdir, withIntermediateDirectories: true)
                let bd = bdir.appendingPathComponent(dst.lastPathComponent)
                if !fm.fileExists(atPath: bd.path) { do { try fm.copyItem(at: dst, to: bd) } catch { r.errors.append("백업 \(dst.lastPathComponent): \(error.localizedDescription)") } }
            }
            r.imported.append(dst)
        }
        // 카탈로그 등록 (한 번의 가져오기 묶음)
        let folders = Set(r.imported.map { $0.deletingLastPathComponent() })
        guard let batch = try? catalog.nextBatch() else { return r }
        let now = Date().timeIntervalSince1970
        for f in folders { _ = try? catalog.folderID(f.standardizedFileURL.path) }
        try? catalog.db.transaction {
            for u in r.imported {
                let fid = try catalog.folderID(u.deletingLastPathComponent().standardizedFileURL.path)
                try catalog.db.run("""
                    INSERT OR IGNORE INTO images(folder_id, filename, path, imported_at, import_batch, capture_date, source)
                    VALUES(?, ?, ?, ?, ?, ?, 'import')
                    """, [fid, u.lastPathComponent, u.standardizedFileURL.path, now, batch, captureDate(u)?.timeIntervalSince1970])
                try catalog.db.run("UPDATE images SET import_batch = ?, offline = 0 WHERE path = ?", [batch, u.standardizedFileURL.path])
            }
        }
        return r
    }
}

final class ImportSheet {
    static func ask(source: URL) -> PhotoImporter.Options? {
        let a = NSAlert()
        a.messageText = "불러오기: \(source.lastPathComponent)"
        a.informativeText = "\(PhotoImporter.files(in: source, recursive: true).count)장 · 제자리 등록은 파일을 옮기지 않습니다."
        let mode = NSPopUpButton(); mode.addItems(withTitles: ["제자리에 등록", "복사해서 불러오기", "옮겨서 불러오기"])
        mode.selectItem(at: UserDefaults.standard.integer(forKey: "import.mode"))
        let dest = NSTextField(string: UserDefaults.standard.string(forKey: "import.dest")
                               ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Duochrome/Imports").path)
        let backup = NSTextField(string: UserDefaults.standard.string(forKey: "import.backup") ?? "")
        backup.placeholderString = "백업 폴더 (비우면 안 함)"
        let name = NSTextField(string: UserDefaults.standard.string(forKey: "import.name") ?? "")
        name.placeholderString = "이름 규칙 (비우면 그대로): {날짜}_{번호}"
        let dateF = NSButton(checkboxWithTitle: "촬영일별 폴더 (yyyy-MM-dd)", target: nil, action: nil)
        dateF.state = UserDefaults.standard.bool(forKey: "import.dateFolders") ? .on : .off
        let sub = NSButton(checkboxWithTitle: "하위 폴더까지", target: nil, action: nil); sub.state = .on
        let style = NSPopUpButton(); style.addItem(withTitle: "스타일 적용 안 함"); style.addItems(withTitles: MainWindowController.styleNames())
        let kw = NSTextField(string: ""); kw.placeholderString = "키워드 (쉼표로 여럿)"
        let xmp = NSButton(checkboxWithTitle: "XMP 사이드카가 있으면 별점·키워드 읽기", target: nil, action: nil); xmp.state = .on
        for f in [dest, backup, name, kw] { f.widthAnchor.constraint(equalToConstant: 320).isActive = true }
        let st = NSStackView(views: [mode, NSTextField(labelWithString: "복사·이동할 곳"), dest, backup, name, dateF, sub, style, kw, xmp])
        st.orientation = .vertical; st.alignment = .leading; st.spacing = 6
        st.frame = NSRect(x: 0, y: 0, width: 330, height: 300)
        a.accessoryView = st
        a.addButton(withTitle: "불러오기"); a.addButton(withTitle: "취소")
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let d = UserDefaults.standard
        d.set(mode.indexOfSelectedItem, forKey: "import.mode"); d.set(dest.stringValue, forKey: "import.dest")
        d.set(backup.stringValue, forKey: "import.backup"); d.set(name.stringValue, forKey: "import.name")
        d.set(dateF.state == .on, forKey: "import.dateFolders")
        var o = PhotoImporter.Options(source: source)
        o.mode = PhotoImporter.Options.Mode(rawValue: mode.indexOfSelectedItem) ?? .inPlace
        o.destination = URL(fileURLWithPath: (dest.stringValue as NSString).expandingTildeInPath)
        o.backup = backup.stringValue.isEmpty ? nil : URL(fileURLWithPath: (backup.stringValue as NSString).expandingTildeInPath)
        o.namePattern = name.stringValue
        o.dateFolders = dateF.state == .on
        o.includeSubfolders = sub.state == .on
        o.style = style.indexOfSelectedItem > 0 ? style.titleOfSelectedItem : nil
        o.keywords = kw.stringValue
        o.readXMP = xmp.state == .on
        return o
    }
}

extension MainWindowController {
    @objc func importPhotos(_ sender: Any?) {
        guard let window else { return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        p.message = "불러올 폴더(메모리 카드 등)를 고르세요."
        p.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let src = p.url, let self, let o = ImportSheet.ask(source: src) else { return }
            self.runImport(o)
        }
    }

    func runImport(_ o: PhotoImporter.Options) {
        let res = PhotoImporter.run(o, catalog: library.catalog) { [weak self] s in self?.window?.subtitle = "불러오는 중 " + s }
        // 불러오며 스타일·키워드·XMP
        library.show(.recentImport)
        let items = library.items
        if let style = o.style, let data = try? Data(contentsOf: Self.stylesFolder.appendingPathComponent("\(style).json")),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for it in items where !library.hasSettings(for: it.url) { library.saveRawSettings(dict, for: it.url) }
        }
        if !o.keywords.isEmpty { addKeywords(o.keywords, to: items) }
        if o.readXMP { for it in items where FileManager.default.fileExists(atPath: Self.sidecarURL(it).path) { _ = readXMP(Self.sidecarURL(it), into: it) } }
        selectSource(.recentImport, title: "최근 가져오기")
        reloadAfterLibraryChange()
        window?.subtitle = "\(res.imported.count)장 불러옴" + (res.skipped > 0 ? ", 이미 있어 건너뜀 \(res.skipped)" : "") + (res.errors.isEmpty ? "" : ", 오류 \(res.errors.count)")
    }

    // MARK: - 여러 장 같이 보정

    var multiEdit: Bool {
        get { UserDefaults.standard.bool(forKey: "multiEdit") }
        set { UserDefaults.standard.set(newValue, forKey: "multiEdit"); browser.setMultipleSelection(newValue) }
    }

    @objc func toggleMultiEdit(_ sender: Any?) {
        multiEdit.toggle()
        window?.subtitle = multiEdit ? "여러 장 같이 보정: 필름스트립에서 ⌘·⇧로 여러 장을 고르면 조정이 모두에 들어갑니다" : (photoItem?.name ?? "")
    }

    /// 지금 사진에서 바뀐 값(사진마다 다른 것 빼고)을 같이 고른 다른 사진에도 적는다
    func propagateMultiEdit(from before: DevelopSettings, to after: DevelopSettings) {
        guard multiEdit, let cur = photoItem else { return }
        let others = (mode == .library ? libraryMode.grid.selectedItems : browser.selectedItems).filter { $0 !== cur && !$0.offline }
        guard !others.isEmpty else { return }
        let a = settingsDict(before), b = settingsDict(after)
        var changed: [String: Any] = [:]
        for (k, v) in b where !Self.batchExcluded.contains(k) {
            if let old = a[k], NSDictionary(dictionary: [k: old]).isEqual(to: [k: v]) { continue }
            changed[k] = v
        }
        guard !changed.isEmpty else { return }
        for it in others {
            var dict = (library.rawSettings(for: it.url).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            for (k, v) in changed { dict[k] = v }
            library.saveRawSettings(dict, for: it.url)
            it.edited = true
            it.thumbnail = nil
            refreshItem(it)
        }
    }

    // MARK: - 스타일 브러시 (스타일을 붓으로 칠하기)

    /// 스타일 값을 레이어 조정으로 옮긴 브러시 레이어를 만들고 마스크 붓을 든다
    @objc func styleBrush(_ sender: Any?) {
        guard let doc = photo else { NSSound.beep(); return }
        let names = Self.styleNames()
        guard !names.isEmpty else {
            let a = NSAlert(); a.messageText = "저장된 스타일이 없습니다"; a.informativeText = "사진 → 스타일에서 먼저 저장하거나 스타일 파일(.costyle)을 가져오세요."; a.runModal(); return
        }
        let a = NSAlert()
        a.messageText = "스타일 브러시"
        a.informativeText = "고른 스타일을 붓으로 칠한 곳에만 겁니다 (노출·대비·밝기·채도·클래리티·디헤이즈·화이트 밸런스·하이라이트·섀도)."
        let pop = NSPopUpButton(); pop.addItems(withTitles: names)
        a.accessoryView = pop
        a.addButton(withTitle: "칠하기"); a.addButton(withTitle: "취소")
        guard a.runModal() == .alertFirstButtonReturn, let name = pop.titleOfSelectedItem,
              let data = try? Data(contentsOf: Self.stylesFolder.appendingPathComponent("\(name).json")),
              let style = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var s = doc.settings
        var l = AdjustLayer(name: "스타일 브러시 · \(name)")
        l.mask.kind = .brush
        l.adjust = Self.localAdjust(fromStyle: style, current: doc.settings)
        s.layers.append(l)
        replaceSettings(s, recordUndo: true, label: "스타일 브러시")
        layersTab.select(l.id)
        enterTool(.mask)
    }

    /// 스타일(전역 조정 사전) → 레이어 조정. 색온도는 지금 값과의 차이를 레이어 단위(−100~100)로.
    static func localAdjust(fromStyle d: [String: Any], current: DevelopSettings) -> LocalAdjust {
        var a = LocalAdjust()
        func f(_ k: String) -> Float? { (d[k] as? NSNumber)?.floatValue }
        if let v = f("exposure") { a.exposure = v - current.exposure }
        if let v = f("contrast") { a.contrast = v }
        if let v = f("brightness") { a.brightness = v }
        if let v = f("saturation") { a.saturation = v }
        if let v = f("clarity") { a.clarity = v }
        if let v = f("dehaze") { a.dehaze = v }
        if let v = f("highlight") { a.highlight = v }
        if let v = f("highlights") { a.highlights = v }
        if let v = f("shadow") { a.shadow = v }
        if let v = f("temperature") { a.temperature = max(-100, min(100, (v - current.temperature) / 25)) }
        if let v = f("tint") { a.tint = max(-100, min(100, v - current.tint)) }
        return a
    }

    // MARK: - 룩 맞추기 (기준 사진의 색감에 맞추기) — Reinhard 색 옮기기(Lab 평균·표준편차)

    static func labStats(_ img: CIImage) -> [Float] {
        let small = img.transformed(by: .init(scaleX: 256 / max(img.extent.width, 1), y: 256 / max(img.extent.width, 1)))
        let r = small.extent.integral
        let w = Int(r.width), h = Int(r.height)
        guard w > 0, h > 0 else { return [50, 0, 0, 20, 10, 10] }
        var px = [Float](repeating: 0, count: w * h * 4)
        Render.context.render(small, toBitmap: &px, rowBytes: w * 16, bounds: r, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var sum = SIMD3<Float>(0, 0, 0), sq = SIMD3<Float>(0, 0, 0)
        let n = Float(w * h)
        for i in 0 ..< w * h {
            let lab = PSDAdjust.toLab(simd_clamp(SIMD3(px[i * 4], px[i * 4 + 1], px[i * 4 + 2]), SIMD3(repeating: 0), SIMD3(repeating: 1)))
            sum += lab; sq += lab * lab
        }
        let mean = sum / n
        let sd = simd_max((sq / n - mean * mean), SIMD3(repeating: 1e-4)).squareRoot()
        return [mean.x, mean.y, mean.z, sd.x, sd.y, sd.z]
    }

    /// 기준 통계(ref)에 맞추는 색 함수 (sRGB → sRGB). 강도 0~1.
    static func lookTransfer(from src: [Float], to ref: [Float], strength: Float = 1) -> PSDAdjust.Fn {
        { v in
            let lab = PSDAdjust.toLab(v)
            var o = SIMD3<Float>(0, 0, 0)
            for c in 0 ..< 3 {
                let k = min(max(ref[c + 3] / max(src[c + 3], 1e-3), 0.3), 3)
                o[c] = (lab[c] - src[c]) * k + ref[c]
            }
            let out = PSDAdjust.fromLab(o)
            return v + (out - v) * strength
        }
    }

    @objc func setLookReference(_ sender: Any?) {
        guard let doc = photo else { NSSound.beep(); return }
        UserDefaults.standard.set(Self.labStats(doc.image(scale: 1.0 / 8)), forKey: "look.reference")
        UserDefaults.standard.set(doc.url.lastPathComponent, forKey: "look.referenceName")
        window?.subtitle = "룩 맞추기 기준: \(doc.url.lastPathComponent)"
    }

    @objc func matchLook(_ sender: Any?) {
        guard let doc = photo, let ref = UserDefaults.standard.array(forKey: "look.reference") as? [Float], ref.count == 6 else {
            let a = NSAlert(); a.messageText = "먼저 기준 사진을 정하세요"; a.informativeText = "기준으로 삼을 사진을 열고 사진 → 룩 맞추기 기준으로 삼기."; a.runModal(); return
        }
        var s = doc.settings
        // 레이어 없이 본 지금 사진의 색
        var bare = s; bare.layers = []
        doc.settings = bare
        let src = Self.labStats(doc.image(scale: 1.0 / 8))
        doc.settings = s
        let fn = Self.lookTransfer(from: src, to: ref)
        guard let file = try? LayerImageStore.importData(Data(PSDAdjust.cube(fn, title: "룩 맞추기").utf8), ext: "cube") else { return }
        var l = AdjustLayer(name: "룩 맞추기 · \(UserDefaults.standard.string(forKey: "look.referenceName") ?? "기준")")
        l.adjust.lut = file
        s.layers.insert(l, at: 0)
        replaceSettings(s, recordUndo: true, label: "룩 맞추기")
        layersTab.select(l.id)
    }

    // MARK: - 노멀라이즈 (특정 색을 기준색으로)

    @objc func pickNormalizeReference(_ sender: Any?) {
        colorPickPurpose = 20
        enterTool(.colorPick)
        window?.subtitle = "노멀라이즈: 기준이 될 색을 사진에서 누르세요"
    }

    @objc func pickNormalizeTarget(_ sender: Any?) {
        guard UserDefaults.standard.array(forKey: "normalize.reference") != nil else { pickNormalizeReference(nil); return }
        colorPickPurpose = 21
        enterTool(.colorPick)
        window?.subtitle = "노멀라이즈: 기준색으로 맞출 곳을 누르세요"
    }

    /// 스포이트가 집은 색 (화면 값)
    func normalizePicked(_ c: SIMD3<Float>) {
        if colorPickPurpose == 20 {
            UserDefaults.standard.set([c.x, c.y, c.z], forKey: "normalize.reference")
            window?.subtitle = String(format: "노멀라이즈 기준색 R %.0f G %.0f B %.0f", c.x * 255, c.y * 255, c.z * 255)
        } else if let r = UserDefaults.standard.array(forKey: "normalize.reference") as? [Float], r.count == 3, var s = photo?.settings {
            // 선형 값의 비로 채널마다 곱한다 (채널 혼합 대각)
            func lin(_ x: Float) -> Float { pow(max(x, 1e-4), 2.2) }
            let g = (0 ..< 3).map { min(max(lin(r[$0]) / lin(c[$0]), 0.2), 5) }
            var l = AdjustLayer(name: "노멀라이즈")
            l.adjust.mixer = [g[0], 0, 0, 0, g[1], 0, 0, 0, g[2]]
            s.layers.append(l)
            replaceSettings(s, recordUndo: true, label: "노멀라이즈")
            layersTab.select(l.id)
        }
        colorPickPurpose = 0
        enterTool(.pan)
    }
}

// MARK: - 교정쇄 프로파일 (프린터·CMYK 등 아무 ICC)

enum ProofProfile {
    static var current: URL? {
        get { UserDefaults.standard.string(forKey: "proof.profile").map { URL(fileURLWithPath: $0) } }
        set { UserDefaults.standard.set(newValue?.path, forKey: "proof.profile"); cached = nil }
    }
    private static var cached: (Data, Data)?   // (교정 LUT, 색역 밖 표시 LUT)

    static func available() -> [URL] {
        var out: [URL] = []
        for dir in ["/System/Library/ColorSync/Profiles", "/Library/ColorSync/Profiles",
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/ColorSync/Profiles").path] {
            guard let e = FileManager.default.enumerator(atPath: dir) else { continue }
            for case let f as String in e where f.lowercased().hasSuffix(".icc") || f.lowercased().hasSuffix(".icm") {
                out.append(URL(fileURLWithPath: dir).appendingPathComponent(f))
            }
        }
        return out.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// sRGB → 프로파일 → sRGB 왕복 LUT (17³). 색역 밖이면 두 번째 LUT가 1.
    static func luts(_ url: URL, n: Int = 17) -> (Data, Data)? {
        if let c = cached { return c }
        guard let icc = try? Data(contentsOf: url), let space = CGColorSpace(iccData: icc as CFData) else { return nil }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let count = n * n * n
        var src = [Float](repeating: 0, count: count * 3)
        let k = Float(n - 1)
        for b in 0 ..< n { for g in 0 ..< n { for r in 0 ..< n {
            let i = (b * n * n + g * n + r) * 3
            src[i] = Float(r) / k; src[i + 1] = Float(g) / k; src[i + 2] = Float(b) / k
        } } }
        let comps = space.numberOfComponents
        var mid = [Float](repeating: 0, count: count * comps)
        var back = [Float](repeating: 0, count: count * 3)
        guard let there = CGColorConversionInfo(src: srgb, dst: space), let home = CGColorConversionInfo(src: space, dst: srgb) else { return nil }
        let fl = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        let fmt3 = CGColorBufferFormat(version: 0, bitmapInfo: fl, bitsPerComponent: 32, bitsPerPixel: 96, bytesPerRow: count * 12)
        let fmtN = CGColorBufferFormat(version: 0, bitmapInfo: fl, bitsPerComponent: 32, bitsPerPixel: 32 * comps, bytesPerRow: count * comps * 4)
        guard #available(macOS 15, *) else { return nil }
        let ok1 = src.withUnsafeBytes { s in mid.withUnsafeMutableBytes { d in
            there.convert(width: count, height: 1, to: d.baseAddress!, format: fmtN, from: s.baseAddress!, format: fmt3, options: nil)
        } }
        let ok2 = mid.withUnsafeBytes { s in back.withUnsafeMutableBytes { d in
            home.convert(width: count, height: 1, to: d.baseAddress!, format: fmt3, from: s.baseAddress!, format: fmtN, options: nil)
        } }
        guard ok1, ok2 else { return nil }
        var proof = [Float](repeating: 1, count: count * 4), warn = [Float](repeating: 1, count: count * 4)
        for i in 0 ..< count {
            var d: Float = 0
            for c in 0 ..< 3 {
                proof[i * 4 + c] = min(max(back[i * 3 + c], 0), 1)
                d = max(d, abs(back[i * 3 + c] - src[i * 3 + c]))
            }
            let out: Float = d > 0.035 ? 1 : 0
            warn[i * 4] = out; warn[i * 4 + 1] = out; warn[i * 4 + 2] = out
        }
        let r = (proof.withUnsafeBufferPointer { Data(buffer: $0) }, warn.withUnsafeBufferPointer { Data(buffer: $0) })
        cached = r
        return r
    }

    static func apply(_ img: CIImage, warn: Bool) -> CIImage? {
        guard let url = current, let (proof, warnLUT) = luts(url) else { return nil }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let p = img.applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension": 17, "inputCubeData": proof, "inputColorSpace": srgb])
        guard warn else { return p }
        let mask = img.applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension": 17, "inputCubeData": warnLUT, "inputColorSpace": srgb])
        let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: img.extent)
        return gray.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: p, kCIInputMaskImageKey: mask]).cropped(to: img.extent)
    }
}

extension MainWindowController {
    @objc func chooseProofProfile(_ sender: Any?) {
        let a = NSAlert()
        a.messageText = "교정쇄 프로파일"
        a.informativeText = "교정쇄 보기(⌘Y)와 색역 경고(⇧⌘Y)를 이 출력 프로파일로 합니다. 프린터·용지 프로파일이나 CMYK 프로파일을 고르세요."
        let pop = NSPopUpButton()
        pop.addItem(withTitle: "sRGB (웹)")
        let list = ProofProfile.available()
        for u in list { pop.addItem(withTitle: u.deletingPathExtension().lastPathComponent) }
        if let c = ProofProfile.current, let i = list.firstIndex(of: c) { pop.selectItem(at: i + 1) }
        pop.frame = NSRect(x: 0, y: 0, width: 320, height: 26)
        a.accessoryView = pop
        a.addButton(withTitle: "고르기"); a.addButton(withTitle: "취소")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        ProofProfile.current = pop.indexOfSelectedItem == 0 ? nil : list[pop.indexOfSelectedItem - 1]
        viewer.canvas.softProof = true
        viewer.canvas.needsDisplay = true
    }
}

// MARK: - 인쇄

final class PrintImageView: NSView {
    let image: CGImage
    var fill = false
    var marginMM: CGFloat = 10
    var caption: String?
    init(image: CGImage, page: NSSize) {
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: page))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let m = marginMM / 25.4 * 72
        var box = bounds.insetBy(dx: m, dy: m)
        if caption != nil { box.origin.y += 18; box.size.height -= 18 }
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let k = fill ? max(box.width / iw, box.height / ih) : min(box.width / iw, box.height / ih)
        let w = iw * k, h = ih * k
        let r = NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
        ctx.saveGState()
        ctx.clip(to: box)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: r)
        ctx.restoreGState()
        if let c = caption {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.darkGray]
            (c as NSString).draw(at: NSPoint(x: box.minX, y: bounds.minY + m), withAttributes: attrs)
        }
    }
}

extension MainWindowController {
    @objc func printPhoto(_ sender: Any?) {
        guard let doc = photo else { NSSound.beep(); return }
        let img = doc.withFullResolution { doc.image(scale: 1) }
        let space = ProofProfile.current.flatMap { try? Data(contentsOf: $0) }.flatMap { CGColorSpace(iccData: $0 as CFData) }
            .flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.displayP3)!
        guard let cg = Render.context.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: space) else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.orientation = cg.width > cg.height ? .landscape : .portrait
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        let a = NSAlert()
        a.messageText = "인쇄"
        let fit = NSPopUpButton(); fit.addItems(withTitles: ["종이에 맞춤 (여백 안에 다)", "종이 채우기 (잘림)"])
        let margin = NSTextField(string: "10"); margin.widthAnchor.constraint(equalToConstant: 50).isActive = true
        let cap = NSButton(checkboxWithTitle: "아래에 파일 이름·촬영 정보", target: nil, action: nil)
        let st = NSStackView(views: [fit, NSStackView(views: [NSTextField(labelWithString: "여백 (mm)"), margin]), cap])
        st.orientation = .vertical; st.alignment = .leading
        st.frame = NSRect(x: 0, y: 0, width: 280, height: 90)
        a.accessoryView = st
        a.informativeText = "색 관리: " + (ProofProfile.current?.deletingPathExtension().lastPathComponent ?? "Display P3") + " 값으로 보냅니다 (교정쇄 프로파일을 고르면 그 공간)."
        a.addButton(withTitle: "계속…"); a.addButton(withTitle: "취소")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let view = PrintImageView(image: cg, page: info.paperSize)
        view.fill = fit.indexOfSelectedItem == 1
        view.marginMM = CGFloat(Double(margin.stringValue) ?? 10)
        if cap.state == .on { view.caption = "\(doc.url.lastPathComponent)   \(doc.info.camera) \(doc.info.lens) \(doc.info.shutter) \(doc.info.aperture) \(doc.info.iso)" }
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.jobTitle = doc.url.lastPathComponent
        op.printPanel.options.insert([.showsPaperSize, .showsOrientation, .showsScaling, .showsPreview])
        if let window { op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil) } else { op.run() }
    }
}
