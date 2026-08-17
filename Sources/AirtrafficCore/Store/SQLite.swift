import Foundation
import SQLite3

/// Minimal SQLite wrapper. Dependency-free on purpose so the repo builds with
/// nothing but the Apple toolchain.
final class SQLiteDatabase {
    enum SQLiteError: Error, CustomStringConvertible {
        case open(String)
        case prepare(String, sql: String)
        case step(String, sql: String)

        var description: String {
            switch self {
            case .open(let m): "sqlite open: \(m)"
            case .prepare(let m, let sql): "sqlite prepare: \(m) [\(sql)]"
            case .step(let m, let sql): "sqlite step: \(m) [\(sql)]"
            }
        }
    }

    /// A value bindable to a statement parameter.
    enum Value {
        case text(String)
        case int(Int64)
        case real(Double)
        case null
    }

    private var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            throw SQLiteError.open(message)
        }
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String, _ params: [Value] = []) throws {
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw SQLiteError.step(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
    }

    /// Rows changed by the most recent `execute`. Zero after an ignored insert.
    var changes: Int { Int(sqlite3_changes(handle)) }

    func query(_ sql: String, _ params: [Value] = []) throws -> [[String: Value]] {
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        var rows: [[String: Value]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: Value] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_TEXT:
                    row[name] = .text(String(cString: sqlite3_column_text(statement, index)))
                case SQLITE_INTEGER:
                    row[name] = .int(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT:
                    row[name] = .real(sqlite3_column_double(statement, index))
                default:
                    row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    private func prepare(_ sql: String, _ params: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, param) in params.enumerated() {
            let index = Int32(offset + 1)
            switch param {
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, transient)
            case .int(let value): sqlite3_bind_int64(statement, index, value)
            case .real(let value): sqlite3_bind_double(statement, index, value)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }
}

// MARK: - Row helpers

extension [String: SQLiteDatabase.Value] {
    func text(_ key: String) -> String {
        if case .text(let value)? = self[key] { return value }
        return ""
    }

    func textOrNil(_ key: String) -> String? {
        if case .text(let value)? = self[key] { return value }
        return nil
    }

    func int(_ key: String) -> Int64 {
        switch self[key] {
        case .int(let value)?: return value
        case .real(let value)?: return Int64(value)
        default: return 0
        }
    }

    func intOrNil(_ key: String) -> Int64? {
        if case .int(let value)? = self[key] { return value }
        return nil
    }

    func real(_ key: String) -> Double {
        switch self[key] {
        case .real(let value)?: return value
        case .int(let value)?: return Double(value)
        default: return 0
        }
    }
}
