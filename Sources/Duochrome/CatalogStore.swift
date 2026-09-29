import AppKit

/// Gathers adjustments, history, layer images, and previews into one catalog.
///
///     Duochrome.duochromecatalog/
///       catalog.sqlite   photo list, albums, ratings + adjustments and history
///       Assets/          layer images, AI selection masks, LUTs
///       Previews/        previews
enum CatalogMigration {
    struct Report { var adjustments = 0, assets = 0, skipped = 0 }

    /// Moves the old layout (JSON files and layer image folder in Application Support) into the catalog. Done once.
    /// The old folder is kept, not deleted, with "(moved on date)" appended.
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
        // Layer images (test runs don't touch the user's folders)
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

// MARK: - Saving history (undo continues after reopening)

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

    /// Restores saved history. Unused if its last state differs from the current settings (changed elsewhere).
    mutating func restore(_ json: String, current: DevelopSettings) -> Bool {
        guard let s = try? JSONDecoder().decode(Stored.self, from: Data(json.utf8)) else { return false }
        // Snapshots are restored even if the history doesn't match
        if let l = s.snapLabels, let st = s.snapSettings { snapshots = zip(l, st).map { ($0, $1) } }
        guard !s.settings.isEmpty, s.settings.indices.contains(s.index), s.settings[s.index] == current else { return false }
        states = zip(s.labels, s.settings).map { ($0, $1) }
        index = s.index
        return true
    }
}

// MARK: - Backup

enum CatalogBackup {
    /// Copies the catalog to the backup folder as "name date time.duochromecatalog". The DB uses SQLite's online backup, safe while in use.
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
        // Beyond the retention count, move the oldest to the Trash (not deleted outright)
        if keep > 0 {
            let olds = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasPrefix(name + " ") && $0.hasSuffix(".duochromecatalog") }.sorted()
            for o in olds.dropLast(keep) { try? fm.trashItem(at: folder.appendingPathComponent(o), resultingItemURL: nil) }
        }
        AppSettings.lastBackup = Date()
        return dest
    }

    /// Whether the interval (daily/weekly/monthly) is due
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

    /// On quit (per the backup interval setting)
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

    /// Open another catalog / new catalog: save the path and relaunch the app
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
    /// Builds previews for the current photo and two neighbors in the background (so stepping is instant)
    func prefetchPreviews(around item: PhotoItem, current doc: RawDocument) {
        PreviewCache.shared.ensure(url: doc.url, settings: doc.settings)
        guard let i = library.items.firstIndex(where: { $0 === item }) else { return }
        // The next one in the stepping direction first, then one the other way (preparing four at a time hogged the GPU when stepping fast)
        let dir = i >= Self.lastPrefetchIndex ? 1 : -1
        Self.lastPrefetchIndex = i
        let near = [i + dir, i - dir].filter { library.items.indices.contains($0) }.map { library.items[$0] }
        prefetch(near.filter { !$0.offline })
    }

    /// Builds previews for photos from their saved adjustments (or as-shot values).
    /// One at a time in order; requests for photos already stepped past are skipped (fast stepping piled up work and held CPU/memory).
    /// Reads only the as-shot values with a single RAW filter instead of building a whole document.
    func prefetch(_ items: [PhotoItem]) {
        let lib = library
        Self.prefetchGeneration += 1
        let gen = Self.prefetchGeneration
        let jobs = items.filter { $0.url.pathExtension.lowercased() != "psd" && $0.url.pathExtension.lowercased() != "psb" }.map(\.url)
        // Don't prepare while stepping fast (only after 0.6 s dwell; skip if the photo changed meanwhile)
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
