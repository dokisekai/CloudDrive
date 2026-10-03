//
//  RecycleBinStore.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  回收站 SQLite 持久化存储
//

import Foundation
import SQLite3
import CloudDriveSupport
import CloudDrivePersistence

public final class RecycleBinStore: @unchecked Sendable {
    public static let shared = RecycleBinStore()
    
    private let connection: SQLiteConnection
    private let lock = NSRecursiveLock()
    
    public init(dbPath: URL? = nil) {
        let path = dbPath ?? CloudDrivePaths.sharedDirectory.appendingPathComponent("recycle_bin.db")
        self.connection = SQLiteConnection(dbPath: path)
        try? initializeSchema()
    }
    
    private func initializeSchema() throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try connection.getHandle()
        let sql = """
        CREATE TABLE IF NOT EXISTS recycle_bin (
            id TEXT PRIMARY KEY,
            vault_id TEXT NOT NULL,
            file_id TEXT NOT NULL,
            name TEXT NOT NULL,
            original_parent_id TEXT NOT NULL,
            original_remote_path TEXT NOT NULL,
            is_directory INTEGER NOT NULL,
            size INTEGER NOT NULL,
            deleted_at REAL NOT NULL,
            local_backup_path TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_recycle_bin_vault ON recycle_bin(vault_id);
        CREATE INDEX IF NOT EXISTS idx_recycle_bin_deleted ON recycle_bin(deleted_at);
        """
        try connection.execute(sql: sql)
    }
    
    public func save(_ item: RecycleBinItem) throws {
        lock.lock()
        defer { lock.unlock() }
        let db = try connection.getHandle()
        let sql = """
        INSERT OR REPLACE INTO recycle_bin (
            id, vault_id, file_id, name, original_parent_id, original_remote_path,
            is_directory, size, deleted_at, local_backup_path
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let stmt = try SQLiteStatement(db: db, sql: sql)
        stmt.bindText(item.id, at: 1)
        stmt.bindText(item.vaultId, at: 2)
        stmt.bindText(item.fileId, at: 3)
        stmt.bindText(item.name, at: 4)
        stmt.bindText(item.originalParentId, at: 5)
        stmt.bindText(item.originalRemotePath, at: 6)
        stmt.bindInt64(item.isDirectory ? 1 : 0, at: 7)
        stmt.bindInt64(item.size, at: 8)
        stmt.bindDouble(item.deletedAt.timeIntervalSince1970, at: 9)
        if let path = item.localBackupPath {
            stmt.bindText(path, at: 10)
        } else {
            stmt.bindNull(at: 10)
        }
        guard stmt.step() == SQLITE_DONE else {
            throw DatabaseError.stepFailed(sql: sql, code: SQLITE_ERROR, message: "Failed to insert into recycle_bin")
        }
    }
    
    public func getItem(id: String) throws -> RecycleBinItem? {
        lock.lock()
        defer { lock.unlock() }
        let db = try connection.getHandle()
        let sql = """
        SELECT id, vault_id, file_id, name, original_parent_id, original_remote_path,
               is_directory, size, deleted_at, local_backup_path
        FROM recycle_bin WHERE id = ?;
        """
        let stmt = try SQLiteStatement(db: db, sql: sql)
        stmt.bindText(id, at: 1)
        if stmt.step() == SQLITE_ROW {
            return extractItem(from: stmt)
        }
        return nil
    }
    
    public func getItemByFileId(fileId: String) throws -> RecycleBinItem? {
        lock.lock()
        defer { lock.unlock() }
        let db = try connection.getHandle()
        let sql = """
        SELECT id, vault_id, file_id, name, original_parent_id, original_remote_path,
               is_directory, size, deleted_at, local_backup_path
        FROM recycle_bin WHERE file_id = ?;
        """
        let stmt = try SQLiteStatement(db: db, sql: sql)
        stmt.bindText(fileId, at: 1)
        if stmt.step() == SQLITE_ROW {
            return extractItem(from: stmt)
        }
        return nil
    }
    
    public func delete(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let db = try connection.getHandle()
        let sql = "DELETE FROM recycle_bin WHERE id = ?;"
        let stmt = try SQLiteStatement(db: db, sql: sql)
        stmt.bindText(id, at: 1)
        guard stmt.step() == SQLITE_DONE else {
            throw DatabaseError.stepFailed(sql: sql, code: SQLITE_ERROR, message: "Failed to delete from recycle_bin")
        }
    }
    
    public func deleteByFileId(fileId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let db = try connection.getHandle()
        let sql = "DELETE FROM recycle_bin WHERE file_id = ?;"
        let stmt = try SQLiteStatement(db: db, sql: sql)
        stmt.bindText(fileId, at: 1)
        guard stmt.step() == SQLITE_DONE else {
            throw DatabaseError.stepFailed(sql: sql, code: SQLITE_ERROR, message: "Failed to delete from recycle_bin by file_id")
        }
    }
    
    public func deleteByVault(vaultId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let db = try connection.getHandle()
        let sql = "DELETE FROM recycle_bin WHERE vault_id = ?;"
        let stmt = try SQLiteStatement(db: db, sql: sql)
        stmt.bindText(vaultId, at: 1)
        guard stmt.step() == SQLITE_DONE else {
            throw DatabaseError.stepFailed(sql: sql, code: SQLITE_ERROR, message: "Failed to delete vault items from recycle_bin")
        }
    }
    
    public func deleteAll() throws {
        lock.lock()
        defer { lock.unlock() }
        try connection.execute(sql: "DELETE FROM recycle_bin;")
    }
    
    /// 获取早于指定截止日期的过期回收站项（用于清理快照与云端）
    public func getExpiredItems(before cutoffDate: Date) throws -> [RecycleBinItem] {
        lock.lock()
        defer { lock.unlock() }
        let db = try connection.getHandle()
        let sql = """
        SELECT id, vault_id, file_id, name, original_parent_id, original_remote_path,
               is_directory, size, deleted_at, local_backup_path
        FROM recycle_bin WHERE deleted_at < ? ORDER BY deleted_at ASC;
        """
        let stmt = try SQLiteStatement(db: db, sql: sql)
        stmt.bindDouble(cutoffDate.timeIntervalSince1970, at: 1)
        var items: [RecycleBinItem] = []
        while stmt.step() == SQLITE_ROW {
            items.append(extractItem(from: stmt))
        }
        return items
    }
    
    public func listItems(vaultId: String? = nil) throws -> [RecycleBinItem] {
        lock.lock()
        defer { lock.unlock() }
        let db = try connection.getHandle()
        let sql: String
        if let vaultId = vaultId, !vaultId.isEmpty {
            sql = """
            SELECT id, vault_id, file_id, name, original_parent_id, original_remote_path,
                   is_directory, size, deleted_at, local_backup_path
            FROM recycle_bin WHERE vault_id = ? ORDER BY deleted_at DESC;
            """
        } else {
            sql = """
            SELECT id, vault_id, file_id, name, original_parent_id, original_remote_path,
                   is_directory, size, deleted_at, local_backup_path
            FROM recycle_bin ORDER BY deleted_at DESC;
            """
        }
        let stmt = try SQLiteStatement(db: db, sql: sql)
        if let vaultId = vaultId, !vaultId.isEmpty {
            stmt.bindText(vaultId, at: 1)
        }
        var items: [RecycleBinItem] = []
        while stmt.step() == SQLITE_ROW {
            items.append(extractItem(from: stmt))
        }
        return items
    }
    
    public func count(vaultId: String? = nil) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let db = try connection.getHandle()
        let sql = vaultId != nil && !vaultId!.isEmpty
            ? "SELECT COUNT(*) FROM recycle_bin WHERE vault_id = ?;"
            : "SELECT COUNT(*) FROM recycle_bin;"
        let stmt = try SQLiteStatement(db: db, sql: sql)
        if let vaultId = vaultId, !vaultId.isEmpty {
            stmt.bindText(vaultId, at: 1)
        }
        if stmt.step() == SQLITE_ROW {
            return Int(stmt.columnInt64(at: 0))
        }
        return 0
    }
    
    public func totalSize(vaultId: String? = nil) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let db = try connection.getHandle()
        let sql = vaultId != nil && !vaultId!.isEmpty
            ? "SELECT COALESCE(SUM(size), 0) FROM recycle_bin WHERE vault_id = ?;"
            : "SELECT COALESCE(SUM(size), 0) FROM recycle_bin;"
        let stmt = try SQLiteStatement(db: db, sql: sql)
        if let vaultId = vaultId, !vaultId.isEmpty {
            stmt.bindText(vaultId, at: 1)
        }
        if stmt.step() == SQLITE_ROW {
            return stmt.columnInt64(at: 0)
        }
        return 0
    }
    
    private func extractItem(from stmt: SQLiteStatement) -> RecycleBinItem {
        let id = stmt.columnText(at: 0)
        let vaultId = stmt.columnText(at: 1)
        let fileId = stmt.columnText(at: 2)
        let name = stmt.columnText(at: 3)
        let originalParentId = stmt.columnText(at: 4)
        let originalRemotePath = stmt.columnText(at: 5)
        let isDirectory = stmt.columnBool(at: 6)
        let size = stmt.columnInt64(at: 7)
        let deletedAtTimestamp = stmt.columnDouble(at: 8)
        let localBackupPath = stmt.columnOptionalText(at: 9)
        return RecycleBinItem(
            id: id,
            vaultId: vaultId,
            fileId: fileId,
            name: name,
            originalParentId: originalParentId,
            originalRemotePath: originalRemotePath,
            isDirectory: isDirectory,
            size: size,
            deletedAt: Date(timeIntervalSince1970: deletedAtTimestamp),
            localBackupPath: localBackupPath
        )
    }
}
