import Foundation
import ImageIO

/// 사진 관리에 쓰는 카탈로그 확장: 채택·거부, 계층형 키워드, 스마트 앨범 규칙, 변형본, IPTC 메타데이터,
/// 촬영 정보 색인(검색용), 이름 바꾸기·원본 다시 잇기.
extension Catalog {
    /// 예전 카탈로그에도 새 열·표를 더한다 (이미 있으면 그대로)
    func migrateExtras() throws {
        for sql in ["ALTER TABLE images ADD COLUMN flag INTEGER NOT NULL DEFAULT 0",
                    "ALTER TABLE images ADD COLUMN variant_of INTEGER",
                    "ALTER TABLE images ADD COLUMN iso REAL", "ALTER TABLE images ADD COLUMN aperture REAL",
                    "ALTER TABLE images ADD COLUMN focal REAL", "ALTER TABLE images ADD COLUMN shutter REAL",
                    "ALTER TABLE images ADD COLUMN exif_done INTEGER NOT NULL DEFAULT 0",
                    "ALTER TABLE albums ADD COLUMN rule TEXT"] {
            _ = try? db.exec(sql)
        }
        // 예전 이름의 가져오기 열·표시를 새 이름으로 (한 번만)
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
        // 조정 표시를 한 번 채운다 (그 뒤로는 저장할 때마다)
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

    /// 저장된 경로("…/a.CR3#v2") → 파일 URL (변형본은 조각을 붙인다)
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

    /// 조정값이 있는 사진 (조정 표의 열쇠는 경로 해시라 SQL로는 못 거른다 → 열쇠 목록을 먼저 만든다)
    static var editedSQL: String { "id IN (SELECT image_id FROM image_meta WHERE key = '_edited' AND value = '1')" }

    // MARK: - 채택·거부

    func setFlag(_ ids: [Int64], _ flag: Int) throws {
        try db.transaction { for id in ids { try db.run("UPDATE images SET flag = ? WHERE id = ?", [flag, id]) } }
    }

    // MARK: - 키워드 (계층: "장소>서울>종로")

    struct Keyword { let id: Int64; let name: String; let parent: Int64?; let count: Int }

    /// "상위>하위" 경로의 키워드 번호 (없으면 만든다)
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

    /// 키워드 전체 경로 ("장소>서울")
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

    // MARK: - 메타데이터 (IPTC 핵심: 제목·설명·작성자·저작권·도시·나라·위치)

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

    /// 조정 여부 표시 (스마트 앨범·검색에서 쓴다)
    func markEdited(_ path: URL, _ on: Bool) {
        let p = Self.storedPath(path)
        guard let id = try? db.scalar("SELECT COALESCE(MAX(id), 0) FROM images WHERE path = ?", [p]), id != 0 else { return }
        try? setMetadata([id], "_edited", on ? "1" : nil)
    }

    // MARK: - 스마트 앨범

    struct SmartRule: Codable, Equatable {
        var minRating = 0
        var color = 0              // 0 상관없음
        var flag = 0               // 1 채택만, -1 거부만, 2 거부 빼고
        var keyword = ""           // 경로 일부
        var camera = ""
        var lens = ""
        var name = ""
        var editedOnly = false
        var isoMin: Double = 0, isoMax: Double = 0
        var daysRecent = 0         // 최근 N일 안에 찍은 것

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

    // MARK: - 변형본

    /// 같은 원본에 조정을 따로 두는 변형본을 만든다. 저장 경로는 "원본#v2".
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

    // MARK: - 경로 바꾸기 (이름 바꾸기·원본 다시 잇기)

    /// 사진 경로를 바꾸고 조정값·작업 내역 열쇠도 옮긴다. 변형본도 같이 옮긴다.
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

    // MARK: - 촬영 정보 색인 (검색·스마트 앨범용)

    /// 아직 읽지 않은 사진의 카메라·렌즈·ISO·조리개·초점 거리·셔터·촬영 시각을 채운다 (오프라인은 건너뛴다)
    /// 촬영 정보 한 장 (파일에서 읽은 값) — 뒤 스레드에서 읽는다
    struct ExifRow { var id: Int64; var cam, lens: String?; var iso, ap, focal, sh, date: Double? }

    private static let exifDate: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; return f }()

    /// 아직 색인하지 않은 사진 (주 스레드, DB)
    func exifTodo(limit: Int) -> [(Int64, String)] {
        var todo: [(Int64, String)] = []
        try? db.query("SELECT id, path FROM images WHERE exif_done = 0 AND offline = 0 AND path NOT LIKE '%#v%' LIMIT ?", [limit]) {
            todo.append(($0.int(0), $0.text(1) ?? ""))
        }
        return todo
    }

    /// 파일에서 촬영 정보를 읽는다 (어느 스레드에서나)
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

    /// 읽은 값을 DB에 (주 스레드)
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

    /// 검색 조건 (카메라:·렌즈:·키워드:·iso>·f<·mm>·채택·거부·조정·변형) → 맞는 사진 번호. 조건이 없으면 nil.
    func searchIDs(_ tokens: [String]) -> Set<Int64>? {
        var w: [String] = [], a: [Any?] = []
        for t in tokens {
            let low = t.lowercased()
            func num(_ prefix: String) -> Double? { low.hasPrefix(prefix) ? Double(low.dropFirst(prefix.count)) : nil }
            if low.hasPrefix("카메라:") { w.append("camera LIKE ?"); a.append("%\(t.dropFirst(4))%") }
            else if low.hasPrefix("렌즈:") { w.append("lens LIKE ?"); a.append("%\(t.dropFirst(3))%") }
            else if low.hasPrefix("키워드:") {
                // 상위 키워드로 찾으면 아래 키워드가 붙은 사진도 나온다
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

    /// 검색 조건으로 쓰이는 낱말인가 (이름 검색에서 뺀다)
    static func isSearchToken(_ t: String) -> Bool {
        let low = t.lowercased()
        return ["카메라:", "렌즈:", "키워드:", "iso>", "iso<", "f<", "f>", "mm>", "mm<"].contains { low.hasPrefix($0) }
            || ["채택", "거부", "조정", "변형"].contains(low) || metaFields.contains { low.hasPrefix($0.title + ":") }
    }
}
