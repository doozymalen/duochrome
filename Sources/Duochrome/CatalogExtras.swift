import Foundation
import ImageIO

/// Catalog extensions for photo management: pick/reject, hierarchical keywords, smart album rules, variants, IPTC metadata,
/// capture info index (for search), rename and relink.
extension Catalog {
    /// Adds new columns/tables to older catalogs too (no-op if present)
    func migrateExtras() throws {
        for sql in ["ALTER TABLE images ADD COLUMN flag INTEGER NOT NULL DEFAULT 0",
                    "ALTER TABLE images ADD COLUMN variant_of INTEGER",
                    "ALTER TABLE images ADD COLUMN iso REAL", "ALTER TABLE images ADD COLUMN aperture REAL",
                    "ALTER TABLE images ADD COLUMN focal REAL", "ALTER TABLE images ADD COLUMN shutter REAL",
                    "ALTER TABLE images ADD COLUMN exif_done INTEGER NOT NULL DEFAULT 0",
                    "ALTER TABLE albums ADD COLUMN rule TEXT"] {
            _ = try? db.exec(sql)
        }
        // Rename old import columns/flags to the new names (once)
        if meta("import.rename.v1") == nil {
            _ = try? db.exec("ALTER TABLE images RENAME COLUMN c1_thumb TO import_thumb")
            _ = try? db.exec("""
            UPDATE images SET source = 'import' WHERE source = 'c1';
            UPDATE albums SET source = 'import' WHERE source = 'c1';
            UPDATE adjustments SET json = replace(json, '"c1WBShift"', '"importWBShift"') WHERE json LIKE '%c1WBShift%';
            """)
            setMeta("import.rename.v1", "1")
        }
        try db.exec("""
        CREATE TABLE IF NOT EXISTS keywords(id INTEGER PRIMARY KEY, name TEXT NOT NULL, parent_id INTEGER, UNIQUE(name, parent_id));
        CREATE TABLE IF NOT EXISTS image_keywords(image_id INTEGER, keyword_id INTEGER, PRIMARY KEY(image_id, keyword_id));
        CREATE TABLE IF NOT EXISTS image_meta(image_id INTEGER, key TEXT, value TEXT, PRIMARY KEY(image_id, key));
        """)
        // Fill the adjusted flag once (then on every save)
        if meta("edited.v1") == nil {
            let keys = adjustedKeys()
            var rows: [(Int64, String)] = []
            try db.query("SELECT id, path FROM images") { rows.append(($0.int(0), $0.text(1) ?? "")) }
            try db.transaction {
                for (id, p) in rows where keys.contains(Library.key(for: Self.url(forStoredPath: p))) {
                    try db.run("INSERT OR REPLACE INTO image_meta VALUES(?, '_edited', '1')", [id])
                }
            }
            setMeta("edited.v1", "1")
        }
    }

    /// Stored path ("…/a.CR3#v2") → file URL (variants append a fragment)
    static func url(forStoredPath p: String) -> URL {
        if let r = p.range(of: "#v", options: .backwards), Int(p[r.upperBound...]) != nil {
            var c = URLComponents(url: URL(fileURLWithPath: String(p[..<r.lowerBound])), resolvingAgainstBaseURL: false)!
            c.fragment = "v" + p[r.upperBound...]
            return c.url!
        }
        return URL(fileURLWithPath: p)
    }

    static func storedPath(_ url: URL) -> String {
        url.standardizedFileURL.path + (url.fragment.map { "#" + $0 } ?? "")
    }

    /// Photos with adjustments (the adjustments table is keyed by path hash, so SQL can't filter → build the key list first)
    static var editedSQL: String { "id IN (SELECT image_id FROM image_meta WHERE key = '_edited' AND value = '1')" }

    // MARK: - Pick / reject

    func setFlag(_ ids: [Int64], _ flag: Int) throws {
        try db.transaction { for id in ids { try db.run("UPDATE images SET flag = ? WHERE id = ?", [flag, id]) } }
    }

    // MARK: - Keywords (hierarchy: "Places>Seoul>Jongno")

    struct Keyword { let id: Int64; let name: String; let parent: Int64?; let count: Int }

    /// Keyword id for a "parent>child" path (created if missing)
    func keywordID(_ path: String) throws -> Int64 {
        var parent: Int64?
        var id: Int64 = 0
        for part in path.split(separator: ">").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            let existing: Int64 = parent == nil
                ? try db.scalar("SELECT COALESCE(MAX(id), 0) FROM keywords WHERE name = ? AND parent_id IS NULL", [part])
                : try db.scalar("SELECT COALESCE(MAX(id), 0) FROM keywords WHERE name = ? AND parent_id = ?", [part, parent])
            id = existing != 0 ? existing : try db.run("INSERT INTO keywords(name, parent_id) VALUES(?, ?)", [part, parent])
            parent = id
        }
        return id
    }

    func addKeywords(_ ids: [Int64], _ paths: [String]) throws {
        let kids = try paths.map { try keywordID($0) }.filter { $0 != 0 }
        try db.transaction {
            for id in ids { for k in kids { try db.run("INSERT OR IGNORE INTO image_keywords VALUES(?, ?)", [id, k]) } }
        }
    }

    func removeKeyword(_ ids: [Int64], _ keyword: Int64) throws {
        try db.transaction { for id in ids { try db.run("DELETE FROM image_keywords WHERE image_id = ? AND keyword_id = ?", [id, keyword]) } }
    }

    func allKeywords() -> [Keyword] {
        var out: [Keyword] = []
        try? db.query("""
            SELECT k.id, k.name, k.parent_id, (SELECT COUNT(*) FROM image_keywords ik WHERE ik.keyword_id = k.id)
            FROM keywords k ORDER BY k.name
            """) { out.append(Keyword(id: $0.int(0), name: $0.text(1) ?? "", parent: $0.isNull(2) ? nil : $0.int(2), count: Int($0.int(3)))) }
        return out
    }

    /// Full keyword path ("Places>Seoul")
    func keywordPath(_ id: Int64, in all: [Keyword]? = nil) -> String {
        let list = all ?? allKeywords()
        let by = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var parts: [String] = []
        var cur: Int64? = id
        while let c = cur, let k = by[c], parts.count < 16 { parts.insert(k.name, at: 0); cur = k.parent }
        return parts.joined(separator: ">")
    }

    func keywords(of image: Int64) -> [(Int64, String)] {
        var ids: [Int64] = []
        try? db.query("SELECT keyword_id FROM image_keywords WHERE image_id = ?", [image]) { ids.append($0.int(0)) }
        let all = allKeywords()
        return ids.map { ($0, keywordPath($0, in: all)) }.sorted { $0.1 < $1.1 }
    }

    func deleteKeyword(_ id: Int64) throws {
        try db.transaction {
            var kids: [Int64] = []
            try db.query("""
                WITH RECURSIVE sub(id) AS (SELECT ? UNION ALL SELECT k.id FROM keywords k JOIN sub ON k.parent_id = sub.id) SELECT id FROM sub
                """, [id]) { kids.append($0.int(0)) }
            for k in kids {
                try db.run("DELETE FROM image_keywords WHERE keyword_id = ?", [k])
                try db.run("DELETE FROM keywords WHERE id = ?", [k])
            }
        }
    }

    // MARK: - Metadata (IPTC core: title, description, creator, copyright, city, country, location)

    static let metaFields: [(key: String, title: String)] = [
        ("title", "제목"), ("caption", "설명"), ("creator", "작성자"), ("copyright", "저작권"),
        ("location", "위치"), ("city", "도시"), ("country", "나라"),
    ]

    func metadata(_ image: Int64) -> [String: String] {
        var out: [String: String] = [:]
        try? db.query("SELECT key, value FROM image_meta WHERE image_id = ?", [image]) { out[$0.text(0) ?? ""] = $0.text(1) ?? "" }
        return out
    }

    func setMetadata(_ ids: [Int64], _ key: String, _ value: String?) throws {
        try db.transaction {
            for id in ids {
                if let v = value, !v.isEmpty { try db.run("INSERT OR REPLACE INTO image_meta VALUES(?, ?, ?)", [id, key, v]) } else {
                    try db.run("DELETE FROM image_meta WHERE image_id = ? AND key = ?", [id, key])
                }
            }
        }
    }

    /// Adjusted flag (used by smart albums and search)
    func markEdited(_ path: URL, _ on: Bool) {
        let p = Self.storedPath(path)
        guard let id = try? db.scalar("SELECT COALESCE(MAX(id), 0) FROM images WHERE path = ?", [p]), id != 0 else { return }
        try? setMetadata([id], "_edited", on ? "1" : nil)
    }

    // MARK: - Smart albums

    struct SmartRule: Codable, Equatable {
        var minRating = 0
        var color = 0              // 0 any
        var flag = 0               // 1 picks only, -1 rejects only, 2 all but rejects
        var keyword = ""           // part of the path
        var camera = ""
        var lens = ""
        var name = ""
        var editedOnly = false
        var isoMin: Double = 0, isoMax: Double = 0
        var daysRecent = 0         // shot within the last N days

        func sql() -> (String, [Any?]) {
            var w: [String] = [], a: [Any?] = []
            if minRating > 0 { w.append("rating >= ?"); a.append(minRating) }
            if color > 0 { w.append("color = ?"); a.append(color) }
            switch flag {
            case 1: w.append("flag = 1")
            case -1: w.append("flag = -1")
            case 2: w.append("flag >= 0")
            default: break
            }
            if !keyword.isEmpty {
                w.append("id IN (SELECT ik.image_id FROM image_keywords ik JOIN keywords k ON k.id = ik.keyword_id WHERE k.name LIKE ?)")
                a.append("%\(keyword)%")
            }
            if !camera.isEmpty { w.append("camera LIKE ?"); a.append("%\(camera)%") }
            if !lens.isEmpty { w.append("lens LIKE ?"); a.append("%\(lens)%") }
            if !name.isEmpty { w.append("path LIKE ?"); a.append("%\(name)%") }
            if editedOnly { w.append(Catalog.editedSQL) }
            if isoMin > 0 { w.append("iso >= ?"); a.append(isoMin) }
            if isoMax > 0 { w.append("iso <= ?"); a.append(isoMax) }
            if daysRecent > 0 { w.append("capture_date >= ?"); a.append(Date().timeIntervalSince1970 - Double(daysRecent) * 86400) }
            return (w.isEmpty ? "" : "WHERE " + w.joined(separator: " AND "), a)
        }
    }

    func smartRule(_ album: Int64) -> SmartRule? {
        var text: String?
        try? db.query("SELECT rule FROM albums WHERE id = ?", [album]) { text = $0.text(0) }
        return text.flatMap { try? JSONDecoder().decode(SmartRule.self, from: Data($0.utf8)) }
    }

    @discardableResult
    func addSmartAlbum(_ name: String, rule: SmartRule, parent: Int64? = nil) throws -> Int64 {
        let json = String(decoding: try JSONEncoder().encode(rule), as: UTF8.self)
        return try db.run("INSERT INTO albums(name, parent_id, kind, rule) VALUES(?, ?, 2, ?)", [name, parent, json])
    }

    func setSmartRule(_ album: Int64, _ rule: SmartRule) throws {
        let json = String(decoding: try JSONEncoder().encode(rule), as: UTF8.self)
        try db.run("UPDATE albums SET rule = ? WHERE id = ?", [json, album])
    }

    // MARK: - Variants

    /// Creates a variant with separate adjustments on the same source. Stored path is "source#v2".
    func addVariant(of id: Int64) throws -> URL? {
        var path: String?, folder: Int64 = 0, date: Double?, cam: String?, lens: String?
        try db.query("SELECT path, folder_id, capture_date, camera, lens FROM images WHERE id = ?", [id]) {
            path = $0.text(0); folder = $0.int(1); date = $0.optDouble(2); cam = $0.text(3); lens = $0.text(4)
        }
        guard let p = path else { return nil }
        let base = p.components(separatedBy: "#v").first ?? p
        var n = 2
        while try db.scalar("SELECT COUNT(*) FROM images WHERE path = ?", [base + "#v\(n)"]) > 0 { n += 1 }
        let vp = base + "#v\(n)"
        try db.run("""
            INSERT INTO images(folder_id, filename, path, imported_at, capture_date, camera, lens, source, variant_of)
            VALUES(?, ?, ?, ?, ?, ?, ?, 'variant', ?)
            """, [folder, (base as NSString).lastPathComponent, vp, Date().timeIntervalSince1970, date, cam, lens, id])
        return Self.url(forStoredPath: vp)
    }

    // MARK: - Path changes (rename · relink)

    /// Changes a photo path and moves the adjustment/history keys too. Variants move along.
    func movePath(from old: URL, to new: URL) throws {
        let oldBase = old.standardizedFileURL.path, newBase = new.standardizedFileURL.path
        var rows: [(Int64, String)] = []
        try db.query("SELECT id, path FROM images WHERE path = ? OR path LIKE ?", [oldBase, oldBase + "#v%"]) { rows.append(($0.int(0), $0.text(1) ?? "")) }
        let fid = try folderID(new.deletingLastPathComponent().standardizedFileURL.path)
        try db.transaction {
            for (id, p) in rows {
                let suffix = String(p.dropFirst(oldBase.count))
                let np = newBase + suffix
                let oldKey = Library.key(for: Self.url(forStoredPath: p)), newKey = Library.key(for: Self.url(forStoredPath: np))
                try db.run("UPDATE images SET path = ?, filename = ?, folder_id = ?, offline = 0 WHERE id = ?",
                           [np, new.lastPathComponent, fid, id])
                try db.run("UPDATE OR REPLACE adjustments SET key = ? WHERE key = ?", [newKey, oldKey])
                try db.run("UPDATE OR REPLACE history SET key = ? WHERE key = ?", [newKey, oldKey])
            }
        }
    }

    // MARK: - Capture info index (for search and smart albums)

    /// Fills camera, lens, ISO, aperture, focal length, shutter, and capture time for unread photos (skips offline)
    /// Capture info for one photo (read from the file) — read on a background thread
    struct ExifRow { var id: Int64; var cam, lens: String?; var iso, ap, focal, sh, date: Double? }

    private static let exifDate: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; return f }()

    /// Photos not indexed yet (main thread, DB)
    func exifTodo(limit: Int) -> [(Int64, String)] {
        var todo: [(Int64, String)] = []
        try? db.query("SELECT id, path FROM images WHERE exif_done = 0 AND offline = 0 AND path NOT LIKE '%#v%' LIMIT ?", [limit]) {
            todo.append(($0.int(0), $0.text(1) ?? ""))
        }
        return todo
    }

    /// Reads capture info from a file (any thread)
    static func readExif(_ id: Int64, _ path: String) -> ExifRow {
        var r = ExifRow(id: id)
        if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let aux = p[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
            r.cam = tiff[kCGImagePropertyTIFFModel] as? String
            r.lens = (exif[kCGImagePropertyExifLensModel] ?? aux[kCGImagePropertyExifAuxLensModel]) as? String
            r.iso = ((exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first ?? exif[kCGImagePropertyExifISOSpeed] as? Int
                     ?? exif[kCGImagePropertyExifRecommendedExposureIndex] as? Int).map(Double.init)
            r.ap = exif[kCGImagePropertyExifFNumber] as? Double
            r.focal = exif[kCGImagePropertyExifFocalLength] as? Double
            r.sh = exif[kCGImagePropertyExifExposureTime] as? Double
            if let d = exif[kCGImagePropertyExifDateTimeOriginal] as? String { r.date = exifDate.date(from: d)?.timeIntervalSince1970 }
        }
        return r
    }

    /// Writes read values to the DB (main thread)
    func storeExif(_ rows: [ExifRow]) {
        for r in rows {
            _ = try? db.run("""
                UPDATE images SET camera = COALESCE(?, camera), lens = COALESCE(?, lens), iso = ?, aperture = ?, focal = ?, shutter = ?,
                    capture_date = COALESCE(?, capture_date), exif_done = 1 WHERE id = ?
                """, [r.cam, r.lens, r.iso, r.ap, r.focal, r.sh, r.date, r.id])
        }
    }

    func indexExif(limit: Int = 500) -> Int {
        var todo: [(Int64, String)] = []
        try? db.query("SELECT id, path FROM images WHERE exif_done = 0 AND offline = 0 AND path NOT LIKE '%#v%' LIMIT ?", [limit]) {
            todo.append(($0.int(0), $0.text(1) ?? ""))
        }
        for (id, path) in todo {
            let url = URL(fileURLWithPath: path)
            var cam: String?, lens: String?, iso: Double?, ap: Double?, focal: Double?, sh: Double?, date: Double?
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
                let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
                let aux = p[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
                cam = tiff[kCGImagePropertyTIFFModel] as? String
                lens = (exif[kCGImagePropertyExifLensModel] ?? aux[kCGImagePropertyExifAuxLensModel]) as? String
                iso = ((exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first ?? exif[kCGImagePropertyExifISOSpeed] as? Int
                       ?? exif[kCGImagePropertyExifRecommendedExposureIndex] as? Int).map(Double.init)
                ap = exif[kCGImagePropertyExifFNumber] as? Double
                focal = exif[kCGImagePropertyExifFocalLength] as? Double
                sh = exif[kCGImagePropertyExifExposureTime] as? Double
                if let d = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                    let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"
                    date = f.date(from: d)?.timeIntervalSince1970
                }
            }
            _ = try? db.run("""
                UPDATE images SET camera = COALESCE(?, camera), lens = COALESCE(?, lens), iso = ?, aperture = ?, focal = ?, shutter = ?,
                    capture_date = COALESCE(?, capture_date), exif_done = 1 WHERE id = ?
                """, [cam, lens, iso, ap, focal, sh, date, id])
        }
        return todo.count
    }

    /// Search terms (camera:, lens:, keyword:, iso>, f<, mm>, pick, reject, adjusted, variant) → matching photo ids. nil if no terms.
    func searchIDs(_ tokens: [String]) -> Set<Int64>? {
        var w: [String] = [], a: [Any?] = []
        for t in tokens {
            let low = t.lowercased()
            func num(_ prefix: String) -> Double? { low.hasPrefix(prefix) ? Double(low.dropFirst(prefix.count)) : nil }
            if low.hasPrefix("카메라:") { w.append("camera LIKE ?"); a.append("%\(t.dropFirst(4))%") }
            else if low.hasPrefix("렌즈:") { w.append("lens LIKE ?"); a.append("%\(t.dropFirst(3))%") }
            else if low.hasPrefix("키워드:") {
                // Searching a parent keyword also finds photos with child keywords
                w.append("""
                    id IN (SELECT image_id FROM image_keywords WHERE keyword_id IN (
                        WITH RECURSIVE sub(id) AS (SELECT id FROM keywords WHERE name LIKE ? UNION ALL
                            SELECT k.id FROM keywords k JOIN sub ON k.parent_id = sub.id) SELECT id FROM sub))
                    """)
                a.append("%\(t.dropFirst(4))%")
            }
            else if let v = num("iso>") { w.append("iso > ?"); a.append(v) }
            else if let v = num("iso<") { w.append("iso < ?"); a.append(v) }
            else if let v = num("f<") { w.append("aperture < ?"); a.append(v) }
            else if let v = num("f>") { w.append("aperture > ?"); a.append(v) }
            else if let v = num("mm>") { w.append("focal > ?"); a.append(v) }
            else if let v = num("mm<") { w.append("focal < ?"); a.append(v) }
            else if low == "채택" { w.append("flag = 1") }
            else if low == "거부" { w.append("flag = -1") }
            else if low == "조정" { w.append(Self.editedSQL) }
            else if low == "변형" { w.append("variant_of IS NOT NULL") }
            else if let m = Self.metaFields.first(where: { low.hasPrefix($0.title + ":") }) {
                w.append("id IN (SELECT image_id FROM image_meta WHERE key = ? AND value LIKE ?)")
                a.append(m.key); a.append("%\(t.dropFirst(m.title.count + 1))%")
            }
        }
        guard !w.isEmpty else { return nil }
        var out = Set<Int64>()
        try? db.query("SELECT id FROM images WHERE " + w.joined(separator: " AND "), a) { out.insert($0.int(0)) }
        return out
    }

    /// Whether a word is a search term (excluded from name search)
    static func isSearchToken(_ t: String) -> Bool {
        let low = t.lowercased()
        return ["카메라:", "렌즈:", "키워드:", "iso>", "iso<", "f<", "f>", "mm>", "mm<"].contains { low.hasPrefix($0) }
            || ["채택", "거부", "조정", "변형"].contains(low) || metaFields.contains { low.hasPrefix($0.title + ":") }
    }
}
