import CloudDriveContracts
import CloudDriveSupport
//
//  DirectoryRepository.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  目录仓储数据访问层
//

import Foundation
import SQLite3

/// 目录仓储数据访问层
public final class DirectoryRepository: Sendable {
    private let connection: SQLiteConnection
    
    public init(connection: SQLiteConnection) {
        self.connection = connection
    }
    
    public func insertDirectory(id: String, name: String, parentId: String?, encryptedId: String, remotePath: String, modifiedAt: Date? = nil) throws {
        let db = try connection.getHandle()
        
        let sql = """
        INSERT INTO directories (id, name, parent_id, encrypted_id, remote_path, created_at, modified_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET name=excluded.name, parent_id=excluded.parent_id, encrypted_id=excluded.encrypted_id, remote_path=excluded.remote_path, modified_at=COALESCE(?, directories.modified_at);
        """
        let stmt = try SQLiteStatement(db: db, sql: sql)
        stmt.bindText(id, at: 1)
        stmt.bindText(name, at: 2)
        if let pid = parentId {
            stmt.bindText(pid, at: 3)
        } else {
            stmt.bindNull(at: 3)
        }
        stmt.bindText(encryptedId, at: 4)
        stmt.bindText(remotePath, at: 5)
        let now = Date().timeIntervalSince1970
        stmt.bindDouble(now, at: 6)
        stmt.bindDouble((modifiedAt ?? Date()).timeIntervalSince1970, at: 7)
        if let date = modifiedAt { stmt.bindDouble(date.timeIntervalSince1970, at: 8) } else { stmt.bindNull(at: 8) }
        
        if stmt.step() != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.stepFailed(sql: sql, code: SQLITE_ERROR, message: msg)
        }
    }
    
    public func getDirectory(id: String) throws -> VirtualDirectory? {
        let db = try connection.getHandle()
        
        let sql = """
        SELECT id, name, parent_id, encrypted_id, remote_path, modified_at
        FROM directories WHERE id = ? LIMIT 1;
        """
        let stmt = try SQLiteStatement(db: db, sql: sql)
        stmt.bindText(id, at: 1)
        
        if stmt.step() == SQLITE_ROW {
            return VirtualDirectory(
                id: stmt.columnText(at: 0),
                name: stmt.columnText(at: 1),
                parentId: stmt.columnOptionalText(at: 2),
                encryptedId: stmt.columnText(at: 3),
                remotePath: stmt.columnText(at: 4),
                modifiedAt: Date(timeIntervalSince1970: stmt.columnDouble(at: 5))
            )
        }
        return nil
    }
    
    /// 递归获取目录下所有子孙文件的 ID (使用 SQLite WITH RECURSIVE CTE 毫秒级返回)
    public func getAllDescendantFileIds(directoryId: String) -> [String] {
        guard let db = try? connection.getHandle() else { return [] }
        
        let sql = """
        WITH RECURSIVE Subtree AS (
            SELECT id FROM directories WHERE id = ?
            UNION
            SELECT d.id FROM directories d JOIN Subtree s ON d.parent_id = s.id
        )
        SELECT f.id FROM files f JOIN Subtree s ON f.parent_id = s.id;
        """
        
        do {
            let stmt = try SQLiteStatement(db: db, sql: sql)
            stmt.bindText(directoryId, at: 1)
            
            var result: [String] = []
            while stmt.step() == SQLITE_ROW {
                result.append(stmt.columnText(at: 0))
            }
            return result
        } catch {
            return []
        }
    }
    
    public func deleteDirectory(id: String) throws {
        try connection.withTransaction {
            let db = try connection.getHandle()
            let subtree = "WITH RECURSIVE subtree(id) AS (SELECT id FROM directories WHERE id=? UNION SELECT d.id FROM directories d JOIN subtree s ON d.parent_id=s.id) "
            for sql in [subtree + "DELETE FROM files WHERE parent_id IN (SELECT id FROM subtree);",
                        subtree + "DELETE FROM directories WHERE id IN (SELECT id FROM subtree);"] {
                let stmt = try SQLiteStatement(db: db, sql: sql)
                stmt.bindText(id, at: 1)
                guard stmt.step() == SQLITE_DONE else { throw DatabaseError.stepFailed(sql: sql, code: SQLITE_ERROR, message: String(cString: sqlite3_errmsg(db))) }
            }
        }
    }

    public func moveDirectory(oldId: String, newId: String, newName: String, newParentId: String, newRemotePath: String) throws {
        guard let oldDirectory = try getDirectory(id: oldId) else { throw DatabaseError.notOpened }
        try connection.withTransaction {
            let db = try connection.getHandle()
            func rewrite(table: String, column: String, old: String, new: String) throws {
                let prefix = old.hasSuffix("/") ? old : old + "/"
                let replacement = new.hasSuffix("/") ? new : new + "/"
                let sql = "UPDATE \(table) SET \(column)=? || substr(\(column),length(?)+1) WHERE substr(\(column),1,length(?))=?;"
                let stmt = try SQLiteStatement(db: db, sql: sql)
                stmt.bindText(replacement, at: 1)
                stmt.bindText(prefix, at: 2)
                stmt.bindText(prefix, at: 3)
                stmt.bindText(prefix, at: 4)
                guard stmt.step() == SQLITE_DONE else { throw DatabaseError.stepFailed(sql: sql, code: SQLITE_ERROR, message: String(cString: sqlite3_errmsg(db))) }
            }
            if oldId != newId {
                for table in ["files", "directories"] {
                    try rewrite(table: table, column: "id", old: oldId, new: newId)
                    try rewrite(table: table, column: "parent_id", old: oldId, new: newId)
                    try rewrite(table: table, column: "remote_path", old: oldDirectory.remotePath, new: newRemotePath)
                    let stmt = try SQLiteStatement(db: db, sql: "UPDATE \(table) SET parent_id=? WHERE parent_id=?;")
                    stmt.bindText(newId, at: 1); stmt.bindText(oldId, at: 2)
                    guard stmt.step() == SQLITE_DONE else { throw DatabaseError.stepFailed(sql: "move descendants", code: SQLITE_ERROR, message: String(cString: sqlite3_errmsg(db))) }
                }
            }
            let sql = "UPDATE directories SET id=?, name=?, parent_id=?, remote_path=?, modified_at=? WHERE id=?;"
            let stmt = try SQLiteStatement(db: db, sql: sql)
            stmt.bindText(newId, at: 1); stmt.bindText(newName, at: 2)
            stmt.bindText(newParentId, at: 3); stmt.bindText(newRemotePath, at: 4)
            stmt.bindDouble(Date().timeIntervalSince1970, at: 5); stmt.bindText(oldId, at: 6)
            guard stmt.step() == SQLITE_DONE else { throw DatabaseError.stepFailed(sql: sql, code: SQLITE_ERROR, message: String(cString: sqlite3_errmsg(db))) }
        }
    }
}
