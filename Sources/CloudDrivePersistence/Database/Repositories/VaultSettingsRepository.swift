//
//  VaultSettingsRepository.swift
//  CloudDrivePersistence
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  加密库专属设置仓储（存储于库本地 vfs.db 中，管理该库的回收站、忽略规则等配置）
//

import Foundation
import SQLite3
import CloudDriveContracts
import CloudDriveSupport

/// 加密库专属设置仓储
public final class VaultSettingsRepository: Sendable {
    private let connection: SQLiteConnection
    
    public init(connection: SQLiteConnection) {
        self.connection = connection
    }
    
    public func ensureTableExists() throws {
        guard let db = connection.rawHandle else { throw DatabaseError.notOpened }
        let sql = """
        CREATE TABLE IF NOT EXISTS vault_settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        """
        try connection.execute(sql: sql)
    }
    
    public func get(key: String) throws -> String? {
        try ensureTableExists()
        guard let db = connection.rawHandle else { throw DatabaseError.notOpened }
        let sql = "SELECT value FROM vault_settings WHERE key = ? LIMIT 1;"
        let stmt = try SQLiteStatement(db: db, sql: sql)
        stmt.bindText(key, at: 1)
        if stmt.step() == SQLITE_ROW {
            return stmt.columnText(at: 0)
        }
        return nil
    }
    
    public func set(key: String, value: String) throws {
        try ensureTableExists()
        guard let db = connection.rawHandle else { throw DatabaseError.notOpened }
        let sql = "INSERT OR REPLACE INTO vault_settings (key, value, updated_at) VALUES (?, ?, ?);"
        let stmt = try SQLiteStatement(db: db, sql: sql)
        stmt.bindText(key, at: 1)
        stmt.bindText(value, at: 2)
        stmt.bindDouble(Date().timeIntervalSince1970, at: 3)
        if stmt.step() != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.stepFailed(sql: sql, code: SQLITE_ERROR, message: msg)
        }
    }
    
    public func remove(key: String) throws {
        try ensureTableExists()
        guard let db = connection.rawHandle else { throw DatabaseError.notOpened }
        let sql = "DELETE FROM vault_settings WHERE key = ?;"
        let stmt = try SQLiteStatement(db: db, sql: sql)
        stmt.bindText(key, at: 1)
        if stmt.step() != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.stepFailed(sql: sql, code: SQLITE_ERROR, message: msg)
        }
    }
    
    public func getAll() throws -> [String: String] {
        try ensureTableExists()
        guard let db = connection.rawHandle else { throw DatabaseError.notOpened }
        let sql = "SELECT key, value FROM vault_settings;"
        let stmt = try SQLiteStatement(db: db, sql: sql)
        var results: [String: String] = [:]
        while stmt.step() == SQLITE_ROW {
            let key = stmt.columnText(at: 0)
            let val = stmt.columnText(at: 1)
            results[key] = val
        }
        return results
    }
    
    // MARK: - 常用专属业务配置项
    
    /// 获取当前加密库是否开启回收站（默认关闭 false）
    public func isRecycleBinEnabled() throws -> Bool {
        guard let val = try get(key: "recycle_bin_enabled") else {
            return false // 默认关闭
        }
        return val == "true" || val == "1"
    }
    
    /// 设置当前加密库是否开启回收站
    public func setRecycleBinEnabled(_ enabled: Bool) throws {
        try set(key: "recycle_bin_enabled", value: enabled ? "true" : "false")
    }
    
    /// 获取当前加密库持久化的忽略规则内容
    public func getIgnoreRules() throws -> String? {
        try get(key: "ignore_rules")
    }
    
    /// 设置当前加密库持久化的忽略规则内容
    public func setIgnoreRules(_ rules: String) throws {
        try set(key: "ignore_rules", value: rules)
    }
}
