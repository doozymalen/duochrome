import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// One photo shown in the browser.
final class PhotoItem {
    /// Source file. Variants carry a fragment (#v2) — the file path (`url.path`) is the same, only the adjustment key differs.
    let url: URL
    var name: String { variant > 0 ? "\(url.lastPathComponent) (변형 \(variant))" : url.lastPathComponent }
    /// Variant number (0 = original)
    var variant: Int { url.fragment.flatMap { $0.hasPrefix("v") ? Int($0.dropFirst()) : nil } ?? 0 }
    /// pick 1, reject -1
    var flag = 0
    /// Catalog id (0 = outside the catalog).
    var id: Int64 = 0
    /// Rating 0–5, color tag 0 (none)–7 (red, orange, yellow, green, blue, pink, purple).
    var rating = 0
    var color = 0
    /// The source file isn't at its path (e.g. imported from an external catalog and the file was moved).
    var offline = false
    /// Imported thumbnail cache (JPEG with adjustments applied).
    var importThumb: String?
    /// Whether adjustments are saved. Shown in the browser.
    var edited = false
    var thumbnail: NSImage?

    init(url: URL) { self.url = url }
}

/// The current photo collection and adjustment storage. The photo list comes from the catalog (`Catalog`).
///
/// Adjustments are kept in `~/Library/Application Support/Duochrome/Adjustments`, named by photo path hash,
/// so photo folders are never touched.
final class Library {
    let catalog: Catalog
    private(set) var folder: URL?
    private(set) var source: Catalog.Source = .all
    private(set) var items: [PhotoItem] = []
    /// Full list before search
    private var allItems: [PhotoItem] = []
    /// Search query: only photos whose file or folder name contains it. "★3" means 3 stars or more.
    var query = "" { didSet { applyQuery() } }

    private func applyQuery() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { items = allItems; return }
        var minRating = 0
        var words: [String] = []
        let tokens = q.split(separator: " ").map(String.init)
        let ids = catalog.searchIDs(tokens.filter(Catalog.isSearchToken))
        for w in tokens where !Catalog.isSearchToken(w) {
            if w.hasPrefix("★"), let n = Int(w.dropFirst()) { minRating = n }
            else if w.hasPrefix("*"), let n = Int(w.dropFirst()) { minRating = n }
            else { words.append(w) }
        }
        items = allItems.filter { item in
            (ids?.contains(item.id) ?? true) && item.rating >= minRating && words.allSatisfy { item.url.path.localizedCaseInsensitiveContains($0) }
        }
    }

    init(catalog: Catalog) { self.catalog = catalog }

    /// Openable files. RAW formats are those the macOS RAW decoder handles; actual support per camera model is decided by macOS.
    static let supported: Set<String> = [
        "cr3", "cr2", "crw",                // Canon
        "nef", "nrw",                       // Nikon
        "arw", "srf", "sr2",                // Sony
        "raf",                              // Fujifilm
        "orf",                              // OM System · Olympus
        "rw2", "raw", "rwl",                // Panasonic · Leica
        "pef",                              // Pentax
        "srw",                              // Samsung
        "3fr", "fff",                       // Hasselblad
        "iiq",                              // Phase One
        "mos",                              // Leaf
        "erf", "mef", "mrw", "dcr", "kdc",  // Epson · Mamiya · Minolta · Kodak
        "dng",
        "jpg", "jpeg", "tif", "tiff", "png", "heic", "psd", "psb"]

    /// Old adjustments folder (JSON files). Now stored in the catalog DB; this folder is read only when migrating.
    static var legacyStore: URL {
        let env = ProcessInfo.processInfo.environment
        if let custom = env["DUOCHROME_ADJUSTMENTS"] { return URL(fileURLWithPath: custom) }
        if env["DUOCHROME_SNAPSHOT"] != nil || env["DUOCHROME_CATALOG_TEST"] != nil {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("duochrome-test-adjustments")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Duochrome/Adjustments", isDirectory: true)
    }

    private let thumbQueue = DispatchQueue(label: "duochrome.thumbs", qos: .userInitiated, attributes: .concurrent)
    private let thumbLimit = DispatchSemaphore(value: 4)

    /// Registers a folder in the catalog and shows it.
    func open(folder: URL) {
        do {
            let fid = try catalog.addFolder(folder)
            self.folder = folder
            show(.folder(fid))
            UserDefaults.standard.set(folder.path, forKey: "lastFolder")
        } catch {
            NSLog("폴더 등록 실패: \(error)")
        }
    }

    /// Shows one catalog collection.
    func show(_ source: Catalog.Source) {
        self.source = source
        if case .folder = source {} else { folder = nil }
        allItems = (try? catalog.items(source)) ?? []
        applyQuery()
        let adjusted = catalog.adjustedKeys()
        for item in allItems {
            item.edited = adjusted.contains(Self.key(for: item.url))
        }
    }

    func setRating(_ items: [PhotoItem], _ r: Int) {
        try? catalog.setRating(items.map(\.id), r)
        items.forEach { $0.rating = r }
    }

    func setColor(_ items: [PhotoItem], _ c: Int) {
        try? catalog.setColor(items.map(\.id), c)
        items.forEach { $0.color = c }
    }

    // MARK: - Adjustments (stored in the catalog DB; formerly JSON files in Application Support)

    /// Photo path hash (same as the old JSON file names — maps 1:1 when migrating)
    static func key(for photo: URL) -> String {
        // Variants (#v2) are the same file but keep separate adjustments
        let base = photo.standardizedFileURL.path + (photo.fragment.map { "#" + $0 } ?? "")
        return SHA256.hash(data: Data(base.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Saved adjustments JSON as is
    func rawSettings(for photo: URL) -> Data? { catalog.adjustment(Self.key(for: photo)).map { Data($0.utf8) } }

    /// Overlays saved values on the as-shot values. Old files still read as tools are added.
    func loadSettings(for photo: URL, over base: DevelopSettings) -> DevelopSettings? {
        guard let saved = rawSettings(for: photo),
              let savedDict = try? JSONSerialization.jsonObject(with: saved) as? [String: Any],
              let baseData = try? JSONEncoder().encode(base),
              var dict = try? JSONSerialization.jsonObject(with: baseData) as? [String: Any] else { return nil }
        var patch = savedDict
        // Layers are an array, so replaced wholesale. Layer fields missing from old files are filled with layer defaults.
        if let layers = patch["layers"] as? [[String: Any]],
           let defData = try? JSONEncoder().encode(AdjustLayer(name: "")),
           let def = try? JSONSerialization.jsonObject(with: defData) as? [String: Any] {
            patch["layers"] = layers.map { l -> [String: Any] in
                var d = def
                Self.overlay(&d, l)
                return d
            }
        }
        // Also keep optional fields absent from the defaults (gammaBlend, layerComps, channels, etc.)
        Self.overlay(&dict, patch)
        guard let merged = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(DevelopSettings.self, from: merged)
    }

    /// Like merge, but also inserts keys absent from the defaults (empty optional fields).
    private static func overlay(_ into: inout [String: Any], _ from: [String: Any]) {
        for (k, v) in from {
            if var sub = into[k] as? [String: Any], let vs = v as? [String: Any] {
                overlay(&sub, vs)
                into[k] = sub
            } else {
                into[k] = v
            }
        }
    }

    private static func merge(_ into: inout [String: Any], _ from: [String: Any]) {
        for (k, v) in from {
            if var sub = into[k] as? [String: Any], let vs = v as? [String: Any] {
                merge(&sub, vs)
                into[k] = sub
            } else if into[k] != nil {
                into[k] = v
            }
        }
    }


    func removeSettings(for photo: URL) { catalog.setAdjustment(Self.key(for: photo), nil) }

    func hasSettings(for photo: URL) -> Bool {
        catalog.adjustment(Self.key(for: photo)) != nil
    }

    /// Writes a settings fragment brought from another program as is. Overlaid on the as-shot values when read.
    func saveRawSettings(_ dict: [String: Any], for photo: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        catalog.setAdjustment(Self.key(for: photo), String(decoding: data, as: UTF8.self))
        catalog.markEdited(photo, true)
    }

    /// Deletes the file if equal to the as-shot values (back to "not adjusted").
    func saveSettings(_ s: DevelopSettings, asShot: DevelopSettings, for photo: URL) {
        let key = Self.key(for: photo)
        let item = items.first { $0.url == photo }
        if s == asShot {
            catalog.setAdjustment(key, nil)
            item?.edited = false
            catalog.markEdited(photo, false)
            return
        }
        if let data = try? JSONEncoder().encode(s) {
            catalog.setAdjustment(key, String(decoding: data, as: UTF8.self))
            if item?.edited != true { catalog.markEdited(photo, true) }
            item?.edited = true
        }
    }

    // MARK: - Thumbnails

    /// Uses the preview embedded in the RAW. CR3 has a JPEG preview, so it's fast without decoding.
    /// Photos imported from an external catalog use the imported thumbnail (with adjustments) first. Offline photos never read the source
    /// (in a streaming location like Google Drive, reading downloads the whole file).
    func loadThumbnail(_ item: PhotoItem, size: Int = 320, done: @escaping (NSImage?) -> Void) {
        thumbQueue.async { [thumbLimit] in
            thumbLimit.wait()
            defer { thumbLimit.signal() }
            if !item.edited || item.offline, let t = item.importThumb, FileManager.default.fileExists(atPath: t),
               let img = NSImage(contentsOfFile: t) {
                DispatchQueue.main.async { item.thumbnail = img; done(img) }
                return
            }
            if item.offline { DispatchQueue.main.async { done(nil) }; return }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: size,
            ]
            var image: NSImage?
            if let src = CGImageSourceCreateWithURL(item.url as CFURL, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            DispatchQueue.main.async {
                item.thumbnail = image
                done(image)
            }
        }
    }

    /// Rebuilds the thumbnail from the adjusted result (when moving to another photo).
    func refreshThumbnail(_ item: PhotoItem, from doc: RawDocument) {
        if let t = Self.thumbnail(from: doc.image(scale: 1.0 / 8)) { item.thumbnail = t }
    }

    /// Adjusted result image → 320 px long side thumbnail (any thread)
    static func thumbnail(from image: CIImage) -> NSImage? {
        let longSide = max(image.extent.width, image.extent.height)
        guard longSide > 0 else { return nil }
        let k = min(1, 320 / longSide)
        let small = image.transformed(by: .init(scaleX: k, y: k))
        guard let cg = Render.context.createCGImage(small, from: small.extent.integral, format: .RGBA8,
                                                    colorSpace: Render.displaySpace) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
