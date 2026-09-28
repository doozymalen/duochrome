import AppKit

/// 카탈로그 하나에 보정값·작업 내역·레이어 그림·미리보기를 모은다.
///
///     Duochrome.duochromecatalog/
///       catalog.sqlite   사진 목록·앨범·별점 + 보정값(adjustments)·작업 내역(history)
///       Assets/          레이어 그림·AI 선택 마스크·LUT
///       Previews/        미리보기
enum CatalogMigration {
    struct Report { var adjustments = 0, assets = 0, skipped = 0 }

    /// 예전 방식(Application Support의 JSON 파일·레이어 그림 폴더)을 카탈로그 안으로 옮긴다. 한 번만 한다.
    /// 옛 폴더는 지우지 않고 "(옮김 완료 날짜)"를 붙여 남긴다.
    @discardableResult
    static func run(_ catalog: Catalog) -> Report? {
        guard catalog.meta("migrated.v1") == nil else { return nil }
        var r = Report()
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let testRun = env["DUOCHROME_SNAPSHOT"] != nil || env["DUOCHROME_SELFTEST"] != nil || env["DUOCHROME_CATALOG_TEST"] != nil
        let legacy = Library.legacyStore
        if let files = try? fm.contentsOfDirectory(atPath: legacy.path) {
            for f in files where f.hasSuffix(".json") {
                let key = String(f.dropLast(5))
                guard catalog.adjustment(key) == nil,
                      let text = try? String(contentsOf: legacy.appendingPathComponent(f), encoding: .utf8) else { r.skipped += 1; continue }
                catalog.setAdjustment(key, text)
                r.adjustments += 1
            }
        }
        // 레이어 그림 (시험 실행은 사용자 폴더를 건드리지 않는다)
        if !testRun, let files = try? fm.contentsOfDirectory(atPath: LayerImageStore.legacyFolder.path) {
            for f in files {
                let dst = LayerImageStore.url(f)
                guard !fm.fileExists(atPath: dst.path) else { continue }
                if (try? fm.copyItem(at: LayerImageStore.legacyFolder.appendingPathComponent(f), to: dst)) != nil { r.assets += 1 }
            }
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        if !testRun || env["DUOCHROME_ADJUSTMENTS"] == nil {
            for dir in testRun ? [] : [legacy, LayerImageStore.legacyFolder] where fm.fileExists(atPath: dir.path) {
                let done = dir.deletingLastPathComponent().appendingPathComponent("\(dir.lastPathComponent) (옮김 완료 \(stamp))")
                try? fm.moveItem(at: dir, to: done)
            }
        }
        catalog.setMeta("migrated.v1", "\(Date().timeIntervalSince1970)")
        NSLog("카탈로그로 옮김: 보정값 %d, 레이어 그림 %d, 건너뜀 %d", r.adjustments, r.assets, r.skipped)
        return r
    }
}

// MARK: - 작업 내역 저장 (다시 열어도 되돌리기가 이어지게)

extension AdjustHistory {
    struct Stored: Codable {
        var labels: [String]; var settings: [DevelopSettings]; var index: Int
        var snapLabels: [String]? = nil
        var snapSettings: [DevelopSettings]? = nil
    }

    func encoded(limit: Int = 60) -> String? {
        let n = states.count, start = max(0, n - limit)
        var s = Stored(labels: states[start...].map(\.label), settings: states[start...].map(\.settings), index: max(0, index - start))
        if !snapshots.isEmpty { s.snapLabels = snapshots.map(\.label); s.snapSettings = snapshots.map(\.settings) }
        return (try? JSONEncoder().encode(s)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// 저장된 내역을 되살린다. 마지막 상태가 지금 설정과 다르면 쓰지 않는다 (다른 곳에서 바뀐 경우).
    mutating func restore(_ json: String, current: DevelopSettings) -> Bool {
        guard let s = try? JSONDecoder().decode(Stored.self, from: Data(json.utf8)) else { return false }
        // 스냅샷은 내역이 어긋나도 살린다
        if let l = s.snapLabels, let st = s.snapSettings { snapshots = zip(l, st).map { ($0, $1) } }
        guard !s.settings.isEmpty, s.settings.indices.contains(s.index), s.settings[s.index] == current else { return false }
        states = zip(s.labels, s.settings).map { ($0, $1) }
        index = s.index
        return true
    }
}

// MARK: - 백업

enum CatalogBackup {
    /// 카탈로그를 백업 폴더에 "이름 날짜 시각.duochromecatalog"로 복사한다. DB는 쓰는 중에도 안전한 SQLite 백업으로.
    static func run(_ catalog: Catalog, to folder: URL, previews: Bool, keep: Int) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        let name = catalog.url.deletingPathExtension().lastPathComponent
        var dest = folder.appendingPathComponent("\(name) \(f.string(from: Date())).duochromecatalog", isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent("\(name) \(f.string(from: Date()))-\(n).duochromecatalog", isDirectory: true); n += 1
        }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try catalog.db.backup(to: dest.appendingPathComponent("catalog.sqlite").path)
        for sub in ["Assets"] + (previews ? ["Previews"] : []) {
            let src = catalog.url.appendingPathComponent(sub)
            if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: dest.appendingPathComponent(sub)) }
        }
        // 보관 개수를 넘으면 오래된 것부터 휴지통으로 (바로 지우지 않는다)
        if keep > 0 {
            let olds = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasPrefix(name + " ") && $0.hasSuffix(".duochromecatalog") }.sorted()
            for o in olds.dropLast(keep) { try? fm.trashItem(at: folder.appendingPathComponent(o), resultingItemURL: nil) }
        }
        AppSettings.lastBackup = Date()
        return dest
    }

    /// 주기(매일·매주·매달)가 됐는지
    static var due: Bool {
        let days: Double
        switch AppSettings.backupInterval {
        case 3: days = 1
        case 4: days = 7
        case 5: days = 30
        default: return false
        }
        guard let last = AppSettings.lastBackup else { return true }
        return Date().timeIntervalSince(last) > days * 86400 - 3600
    }
}

extension MainWindowController {
    @objc func backupCatalogNowReal(_ sender: Any?) {
        do {
            let dest = try CatalogBackup.run(library.catalog, to: URL(fileURLWithPath: AppSettings.backupFolder),
                                             previews: AppSettings.backupPreviews, keep: AppSettings.backupKeep)
            NSLog("백업: %@", dest.path)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// 앱을 끌 때 (설정의 백업 주기에 따라)
    func backupOnQuit() {
        let env = ProcessInfo.processInfo.environment
        guard env["DUOCHROME_SNAPSHOT"] == nil, env["DUOCHROME_SELFTEST"] == nil else { return }
        switch AppSettings.backupInterval {
        case 1:
            let a = NSAlert()
            a.messageText = "카탈로그를 백업할까요?"
            a.informativeText = "\(AppSettings.backupFolder)에 복사합니다. 설정 → 카탈로그에서 주기를 바꿀 수 있습니다."
            a.addButton(withTitle: "백업")
            a.addButton(withTitle: "건너뛰기")
            if a.runModal() == .alertFirstButtonReturn { backupCatalogNowReal(nil) }
        case 2: backupCatalogNowReal(nil)
        default: if CatalogBackup.due { backupCatalogNowReal(nil) }
        }
    }

    /// 다른 카탈로그 열기 / 새 카탈로그: 경로를 저장하고 앱을 다시 연다
    func switchCatalog(to url: URL) {
        AppSettings.catalogPath = url.path
        var recent = AppSettings.recentCatalogs.filter { $0 != url.path }
        recent.insert(url.path, at: 0)
        AppSettings.recentCatalogs = Array(recent.prefix(8))
        let a = NSAlert()
        a.messageText = "카탈로그를 바꾸려면 Duochrome을 다시 엽니다"
        a.informativeText = url.path
        a.addButton(withTitle: "다시 열기")
        a.addButton(withTitle: "나중에")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let app = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : URL(fileURLWithPath: CommandLine.arguments[0])
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: app, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

extension MainWindowController {
    /// 지금 사진과 앞뒤 두 장의 미리보기를 뒤에서 만든다 (넘길 때 바로 뜨게)
    func prefetchPreviews(around item: PhotoItem, current doc: RawDocument) {
        PreviewCache.shared.ensure(url: doc.url, settings: doc.settings)
        guard let i = library.items.firstIndex(where: { $0 === item }) else { return }
        // 넘기는 방향의 다음 한 장 먼저, 그다음 반대쪽 한 장 (넷씩 준비하면 빨리 넘길 때 GPU를 붙잡았다)
        let dir = i >= Self.lastPrefetchIndex ? 1 : -1
        Self.lastPrefetchIndex = i
        let near = [i + dir, i - dir].filter { library.items.indices.contains($0) }.map { library.items[$0] }
        prefetch(near.filter { !$0.offline })
    }

    /// 사진들의 미리보기를 저장된 조정(없으면 카메라 기록값) 기준으로 만든다.
    /// 한 줄로 차례로 하고, 그사이 다른 사진으로 넘어갔으면 지난 요청은 건너뛴다 (빨리 넘기면 작업이 쌓여 CPU·메모리를 잡았다).
    /// 문서를 다 만들지 않고 RAW 필터 하나로 기록값만 읽는다.
    func prefetch(_ items: [PhotoItem]) {
        let lib = library
        Self.prefetchGeneration += 1
        let gen = Self.prefetchGeneration
        let jobs = items.filter { $0.url.pathExtension.lowercased() != "psd" && $0.url.pathExtension.lowercased() != "psb" }.map(\.url)
        // 사진을 빨리 넘기는 중이면 준비하지 않는다 (0.6초 머문 뒤에만, 그새 다른 사진이면 건너뛴다)
        Self.prefetchQueue.asyncAfter(deadline: .now() + 0.6) {
            for url in jobs {
                BackgroundGate.waitQuiet()
                if gen != Self.prefetchGeneration { return }
                autoreleasepool {
                    guard let shot = RawDocument.shotSettings(url: url) else { return }
                    var s = DispatchQueue.main.sync { lib.loadSettings(for: url, over: shot) } ?? shot
                    s = RawDocument.importedWB(s, over: shot)
                    PreviewCache.shared.ensure(url: url, settings: s)
                }
            }
        }
    }

    static var prefetchGeneration = 0
    static var lastPrefetchIndex = 0
    static let prefetchQueue = DispatchQueue(label: "duochrome.prefetch", qos: .utility)
}
