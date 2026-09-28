import Foundation
import SQLite3

/// macOS에 들어 있는 SQLite를 얇게 감싼 것. 카탈로그와 외부 카탈로그 읽기에 쓴다.
final class SQLiteDB {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private(set) var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "열 수 없음"
            sqlite3_close(handle)
            throw Failure(message: "\(path): \(msg)")
        }
    }

    deinit { sqlite3_close(handle) }

    private func error() -> Failure { Failure(message: String(cString: sqlite3_errmsg(handle))) }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    struct Row {
        let stmt: OpaquePointer
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
        func text(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        func optDouble(_ i: Int32) -> Double? { isNull(i) ? nil : double(i) }
    }

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error() }
        for (k, a) in args.enumerated() {
            let i = Int32(k + 1)
            switch a {
            case nil: sqlite3_bind_null(stmt, i)
            case let v as Int: sqlite3_bind_int64(stmt, i, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, i, v)
            case let v as Double: sqlite3_bind_double(stmt, i, v)
            case let v as Bool: sqlite3_bind_int(stmt, i, v ? 1 : 0)
            case let v as String: sqlite3_bind_text(stmt, i, v, -1, Self.transient)
            default: sqlite3_bind_null(stmt, i)
            }
        }
        return stmt
    }

    func query(_ sql: String, _ args: [Any?] = [], _ each: (Row) throws -> Void) throws {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { try each(Row(stmt: stmt)) } else if rc == SQLITE_DONE { break } else { throw error() }
        }
    }

    @discardableResult
    func run(_ sql: String, _ args: [Any?] = []) throws -> Int64 {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error() }
        return sqlite3_last_insert_rowid(handle)
    }

    func scalar(_ sql: String, _ args: [Any?] = []) throws -> Int64 {
        var v: Int64 = 0
        try query(sql, args) { v = $0.int(0) }
        return v
    }

    /// 쓰는 중에도 안전한 온라인 백업 (SQLite 백업 API)
    func backup(to path: String) throws {
        var dest: OpaquePointer?
        guard sqlite3_open(path, &dest) == SQLITE_OK else { throw Failure(message: "\(path): 열 수 없음") }
        defer { sqlite3_close(dest) }
        guard let b = sqlite3_backup_init(dest, "main", handle, "main") else {
            throw Failure(message: String(cString: sqlite3_errmsg(dest)))
        }
        sqlite3_backup_step(b, -1)
        guard sqlite3_backup_finish(b) == SQLITE_OK else { throw Failure(message: String(cString: sqlite3_errmsg(dest))) }
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }
}
