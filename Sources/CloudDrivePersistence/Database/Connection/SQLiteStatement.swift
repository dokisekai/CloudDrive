import CloudDriveContracts
import CloudDriveSupport
//
//  SQLiteStatement.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  SQLite 预编译语句与参数安全绑定包装
//

import Foundation
import SQLite3

// SQLite3 provides SQLITE_ROW and SQLITE_DONE natively
/// SQLite 预编译语句管理类
public final class SQLiteStatement {
    private let db: OpaquePointer
    private var stmt: OpaquePointer?
    private let sql: String
    
    public init(db: OpaquePointer, sql: String) throws {
        self.db = db
        self.sql = sql
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let s = statement else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.prepareFailed(sql: sql, code: rc, message: msg)
        }
        self.stmt = s
    }
    
    deinit {
        if let s = stmt {
            sqlite3_finalize(s)
        }
    }
    
    public func reset() {
        if let s = stmt {
            sqlite3_reset(s)
            sqlite3_clear_bindings(s)
        }
    }
    
    // MARK: - 参数绑定
    
    public func bindText(_ text: String, at index: Int32) {
        guard let s = stmt else { return }
        _ = text.withCString { sqlite3_bind_text(s, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    
    public func bindInt64(_ value: Int64, at index: Int32) {
        guard let s = stmt else { return }
        sqlite3_bind_int64(s, index, value)
    }
    
    public func bindDouble(_ value: Double, at index: Int32) {
        guard let s = stmt else { return }
        sqlite3_bind_double(s, index, value)
    }
    
    public func bindNull(at index: Int32) {
        guard let s = stmt else { return }
        sqlite3_bind_null(s, index)
    }
    
    public func bindOptionalText(_ text: String?, at index: Int32) {
        if let text { bindText(text, at: index) }
        else { bindNull(at: index) }
    }
    
    public func bindOptionalInt64(_ value: Int64?, at index: Int32) {
        if let value { bindInt64(value, at: index) }
        else { bindNull(at: index) }
    }
    
    public func bindOptionalDouble(_ value: Double?, at index: Int32) {
        if let value { bindDouble(value, at: index) }
        else { bindNull(at: index) }
    }

    public func bindBool(_ value: Bool, at index: Int32) {
        bindInt64(value ? 1 : 0, at: index)
    }

    public func bindOptionalBool(_ value: Bool?, at index: Int32) {
        if let value { bindBool(value, at: index) }
        else { bindNull(at: index) }
    }
    
    // MARK: - 执行与单步步进
    
    public func step() -> Int32 {
        guard let s = stmt else { return SQLITE_ERROR }
        return sqlite3_step(s)
    }
    
    // MARK: - 结果读取
    
    public func columnText(at index: Int32) -> String {
        guard let s = stmt, let text = sqlite3_column_text(s, index) else { return "" }
        return String(cString: text)
    }
    
    public func columnOptionalText(at index: Int32) -> String? {
        guard let s = stmt, sqlite3_column_type(s, index) != SQLITE_NULL,
              let text = sqlite3_column_text(s, index) else { return nil }
        return String(cString: text)
    }
    
    public func columnInt64(at index: Int32) -> Int64 {
        guard let s = stmt else { return 0 }
        return sqlite3_column_int64(s, index)
    }

    public func columnOptionalInt64(at index: Int32) -> Int64? {
        guard let s = stmt, sqlite3_column_type(s, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(s, index)
    }
    
    public func columnDouble(at index: Int32) -> Double {
        guard let s = stmt else { return 0.0 }
        return sqlite3_column_double(s, index)
    }

    public func columnOptionalDouble(at index: Int32) -> Double? {
        guard let s = stmt, sqlite3_column_type(s, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(s, index)
    }

    public func columnBool(at index: Int32) -> Bool {
        return columnInt64(at: index) != 0
    }

    public func columnOptionalBool(at index: Int32) -> Bool? {
        guard let s = stmt, sqlite3_column_type(s, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(s, index) != 0
    }
}
