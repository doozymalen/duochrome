import Foundation

/// Duochrome 카탈로그. 사진 목록, 폴더, 앨범, 별점·색 태그를 관리한다.
/// 조정값은 사진 경로마다 따로 저장하는 기존 방식(`Library`)을 그대로 쓴다.
///
/// 위치: `~/Pictures/Duochrome/Duochrome.duochromecatalog/catalog.sqlite`
final class Catalog {
    let url: URL
    let db: SQLiteDB

    /// 브라우저 왼쪽 목록에서 고르는 사진 묶음.
    enum Source: Equatable {
        case all
        case recentImport
        case folder(Int64)
        case album(Int64)
        case rated(Int)          // 별점 이상
        case offline
        case flag(Int)           // 1 채택, -1 거부
        case keyword(Int64)      // 이 키워드(하위 포함)가 붙은 사진
        case edited              // 조정한 사진
    }

    struct Album {
        let id: Int64
        var name: String
        var parent: Int64?
        /// 0 그룹(앨범을 담는 폴더), 1 앨범
        var kind: Int
        var source: String?      // "import" 이면 외부 카탈로그에서 가져온 것
    }

    struct Folder {
        let id: Int64
        let path: String
    }

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Duochrome/Duochrome.duochromecatalog", isDirectory: true)
    }

    init(url: URL = Catalog.defaultURL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        db = try SQLiteDB(path: url.appendingPathComponent("catalog.sqlite").path)
        try db.exec("""
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS folders(id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL);
        CREATE TABLE IF NOT EXISTS images(
            id INTEGER PRIMARY KEY, folder_id INTEGER, filename TEXT NOT NULL, path TEXT UNIQUE NOT NULL,
            rating INTEGER NOT NULL DEFAULT 0, color INTEGER NOT NULL DEFAULT 0,
            capture_date REAL, imported_at REAL, import_batch INTEGER,
            camera TEXT, lens TEXT, source TEXT, import_thumb TEXT, offline INTEGER NOT NULL DEFAULT 0);
        CREATE INDEX IF NOT EXISTS images_folder ON images(folder_id);
        CREATE TABLE IF NOT EXISTS albums(
            id INTEGER PRIMARY KEY, name TEXT NOT NULL, parent_id INTEGER, kind INTEGER NOT NULL DEFAULT 1,
            sort INTEGER NOT NULL DEFAULT 0, source TEXT, source_key TEXT);
        CREATE TABLE IF NOT EXISTS album_images(album_id INTEGER, image_id INTEGER, PRIMARY KEY(album_id, image_id));
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS adjustments(key TEXT PRIMARY KEY, json TEXT NOT NULL, modified REAL);
        CREATE TABLE IF NOT EXISTS history(key TEXT PRIMARY KEY, json TEXT NOT NULL);
        """)
        try migrateExtras()
    }

    // MARK: - 가져오기

    /// 폴더 안의 사진을 제자리에 둔 채 등록한다 (복사하지 않는다). 이미 있는 사진은 건너뛴다.
    @discardableResult
    func addFolder(_ folder: URL) throws -> Int64 {
        let fid = try folderID(folder.standardizedFileURL.path)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        let batch = try nextBatch()
        let now = Date().timeIntervalSince1970
        try db.transaction {
            for f in files where Library.supported.contains(f.pathExtension.lowercased()) {
                let date = (try? f.resourceValues(forKeys: [.creationDateKey]))?.creationDate?.timeIntervalSince1970
                try db.run("""
                    INSERT OR IGNORE INTO images(folder_id, filename, path, imported_at, import_batch, capture_date, source)
                    VALUES(?, ?, ?, ?, ?, ?, 'folder')
                    """, [fid, f.lastPathComponent, f.standardizedFileURL.path, now, batch, date])
            }
        }
        return fid
    }

    func folderID(_ path: String) throws -> Int64 {
        try db.run("INSERT OR IGNORE INTO folders(path) VALUES(?)", [path])
        return try db.scalar("SELECT id FROM folders WHERE path = ?", [path])
    }

    func nextBatch() throws -> Int64 {
        try db.scalar("SELECT COALESCE(MAX(import_batch), 0) + 1 FROM images")
    }

    // MARK: - 읽기

    func folders() throws -> [Folder] {
        var out: [Folder] = []
        try db.query("SELECT id, path FROM folders ORDER BY path") { out.append(Folder(id: $0.int(0), path: $0.text(1) ?? "")) }
        return out
    }

    func albums() throws -> [Album] {
        var out: [Album] = []
        try db.query("SELECT id, name, parent_id, kind, source FROM albums ORDER BY sort, name") {
            out.append(Album(id: $0.int(0), name: $0.text(1) ?? "", parent: $0.isNull(2) ? nil : $0.int(2),
                             kind: Int($0.int(3)), source: $0.text(4)))
        }
        return out
    }

    func count(_ source: Source) throws -> Int {
        let (w, args) = whereClause(source)
        return Int(try db.scalar("SELECT COUNT(*) FROM images \(w)", args))
    }

    private func whereClause(_ source: Source) -> (String, [Any?]) {
        switch source {
        case .all: return ("", [])
        case .recentImport: return ("WHERE import_batch = (SELECT MAX(import_batch) FROM images)", [])
        case .folder(let id): return ("WHERE folder_id = ?", [id])
        case .album(let id) where smartRule(id) != nil:
            return smartRule(id)!.sql()
        case .album(let id):
            // 그룹이면 안에 든 앨범들의 사진을 모두 보여 준다.
            return ("""
                WHERE id IN (SELECT image_id FROM album_images WHERE album_id IN (
                    WITH RECURSIVE sub(id) AS (SELECT ? UNION ALL SELECT a.id FROM albums a JOIN sub ON a.parent_id = sub.id)
                    SELECT id FROM sub))
                """, [id])
        case .rated(let n): return ("WHERE rating >= ?", [n])
        case .offline: return ("WHERE offline = 1", [])
        case .flag(let f): return ("WHERE flag = ?", [f])
        case .keyword(let k):
            return ("""
                WHERE id IN (SELECT image_id FROM image_keywords WHERE keyword_id IN (
                    WITH RECURSIVE sub(id) AS (SELECT ? UNION ALL SELECT k.id FROM keywords k JOIN sub ON k.parent_id = sub.id)
                    SELECT id FROM sub))
                """, [k])
        case .edited: return ("WHERE \(Self.editedSQL)", [])
        }
    }

    func items(_ source: Source) throws -> [PhotoItem] {
        let (w, args) = whereClause(source)
        var out: [PhotoItem] = []
        try db.query("""
            SELECT id, path, rating, color, offline, import_thumb, flag FROM images \(w)
            ORDER BY COALESCE(capture_date, imported_at), filename, path
            """, args) { r in
            let item = PhotoItem(url: Self.url(forStoredPath: r.text(1) ?? ""))
            item.flag = Int(r.int(6))
            item.id = r.int(0)
            item.rating = Int(r.int(2))
            item.color = Int(r.int(3))
            item.offline = r.int(4) != 0
            item.importThumb = r.text(5)
            out.append(item)
        }
        return out
    }

    // MARK: - 쓰기

    func setRating(_ ids: [Int64], _ rating: Int) throws {
        try db.transaction { for id in ids { try db.run("UPDATE images SET rating = ? WHERE id = ?", [rating, id]) } }
    }

    func setColor(_ ids: [Int64], _ color: Int) throws {
        try db.transaction { for id in ids { try db.run("UPDATE images SET color = ? WHERE id = ?", [color, id]) } }
    }

    @discardableResult
    func addAlbum(_ name: String, parent: Int64? = nil, kind: Int = 1, source: String? = nil, key: String? = nil) throws -> Int64 {
        if let key, let source {
            let existing = try db.scalar("SELECT COALESCE(MAX(id), 0) FROM albums WHERE source = ? AND source_key = ?", [source, key])
            if existing != 0 { return existing }
        }
        return try db.run("INSERT INTO albums(name, parent_id, kind, source, source_key) VALUES(?, ?, ?, ?, ?)",
                          [name, parent, kind, source, key])
    }

    func addToAlbum(_ album: Int64, _ ids: [Int64]) throws {
        try db.transaction { for id in ids { try db.run("INSERT OR IGNORE INTO album_images VALUES(?, ?)", [album, id]) } }
    }

    func removeFromAlbum(_ album: Int64, _ ids: [Int64]) throws {
        try db.transaction { for id in ids { try db.run("DELETE FROM album_images WHERE album_id = ? AND image_id = ?", [album, id]) } }
    }

    func renameAlbum(_ id: Int64, _ name: String) throws { try db.run("UPDATE albums SET name = ? WHERE id = ?", [name, id]) }

    func deleteAlbum(_ id: Int64) throws {
        try db.transaction {
            try db.run("DELETE FROM album_images WHERE album_id = ?", [id])
            try db.run("UPDATE albums SET parent_id = NULL WHERE parent_id = ?", [id])
            try db.run("DELETE FROM albums WHERE id = ?", [id])
        }
    }

    // MARK: - 보정값·작업 내역 (사진 경로 해시가 열쇠)

    func adjustment(_ key: String) -> String? {
        var v: String?
        try? db.query("SELECT json FROM adjustments WHERE key = ?", [key]) { v = $0.text(0) }
        return v
    }

    func setAdjustment(_ key: String, _ json: String?) {
        if let json {
            _ = try? db.run("INSERT OR REPLACE INTO adjustments VALUES(?, ?, ?)", [key, json, Date().timeIntervalSince1970])
        } else {
            _ = try? db.run("DELETE FROM adjustments WHERE key = ?", [key])
            _ = try? db.run("DELETE FROM history WHERE key = ?", [key])
        }
    }

    func adjustedKeys() -> Set<String> {
        var s = Set<String>()
        try? db.query("SELECT key FROM adjustments") { if let k = $0.text(0) { s.insert(k) } }
        return s
    }

    func history(_ key: String) -> String? {
        var v: String?
        try? db.query("SELECT json FROM history WHERE key = ?", [key]) { v = $0.text(0) }
        return v
    }

    func setHistory(_ key: String, _ json: String) {
        _ = try? db.run("INSERT OR REPLACE INTO history VALUES(?, ?)", [key, json])
    }

    func meta(_ key: String) -> String? {
        var v: String?
        try? db.query("SELECT value FROM meta WHERE key = ?", [key]) { v = $0.text(0) }
        return v
    }

    func setMeta(_ key: String, _ value: String) {
        _ = try? db.run("INSERT OR REPLACE INTO meta VALUES(?, ?)", [key, value])
    }
}
