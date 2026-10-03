import CloudDriveContracts
import CloudDriveSupport
//
//  FileItemRepository.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  文件仓储数据访问层
//

import Foundation
import SQLite3

/// 文件项仓储数据访问层
public final class FileItemRepository: Sendable {
    private let connection: SQLiteConnection
    
    public init(connection: SQLiteConnection) {
        self.connection = connection
    }
    
    public func insertFile(id: String, name: String, parentId: String, size: Int64, encryptedName: String, remotePath: String, modifiedAt: Date? = nil) throws {
        let db = try connection.getHandle()
        
        let sql = """
        INSERT INTO files (id, name, parent_id, size, encrypted_name, remote_path, created_at, modified_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET name=excluded.name, parent_id=excluded.parent_id, size=excluded.size, encrypted_name=excluded.encrypted_name, remote_path=excluded.remote_path, modified_at=COALESCE(?, files.modified_at);
        """
        let stmt = try SQLiteStatement(db: db, sql: sql)
        stmt.bindText(id, at: 1)
        stmt.bindText(name, at: 2)
        stmt.bindText(parentId, at: 3)
        stmt.bindInt64(size, at: 4)
        stmt.bindText(encryptedName, at: 5)
        stmt.bindText(remotePath, at: 6)
        let now = Date().timeIntervalSince1970
        stmt.bindDouble(now, at: 7)
        stmt.bindDouble((modifiedAt ?? Date()).timeIntervalSince1970, at: 8)
        if let date = modifiedAt { stmt.bindDouble(date.timeIntervalSince1970, at: 9) } else { stmt.bindNull(at: 9) }
        
        if stmt.step() != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.stepFailed(sql: sql, code: SQLITE_ERROR, message: msg)
        }
    }
    
    public func getFile(id: String) throws -> VirtualFile? {
        let db = try connection.getHandle()
        
        let sql = "SELECT id, name, parent_id, size, encrypted_name, remote_path, modified_at FROM files WHERE id = ?;"
        let stmt = try SQLiteStatement(db: db, sql: sql)
        stmt.bindText(id, at: 1)
        
        if stmt.step() == SQLITE_ROW {
            return VirtualFile(
                id: stmt.columnText(at: 0),
                name: stmt.columnText(at: 1),
                parentId: stmt.columnText(at: 2),
                size: stmt.columnInt64(at: 3),
                encryptedName: stmt.columnText(at: 4),
                remotePath: stmt.columnText(at: 5),
                modifiedAt: Date(timeIntervalSince1970: stmt.columnDouble(at: 6))
            )
        }
        return nil
    }
    
    public func deleteFile(id: String) throws {
        let db = try connection.getHandle()
        
        let sql = "DELETE FROM files WHERE id = ?;"
        let stmt = try SQLiteStatement(db: db, sql: sql)
        stmt.bindText(id, at: 1)
        
        if stmt.step() != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.stepFailed(sql: sql, code: SQLITE_ERROR, message: msg)
        }
    }
    
    /// 获取指定父目录下的所有直接子项 (子目录与子文件合并)
    public func listChildren(parentId: String) throws -> [VirtualFileItem] {
        let db = try connection.getHandle()
        
        var items: [VirtualFileItem] = []
        
        // 1. 查询子目录 (兼顾 parent_id IS NULL 且 parentId == 'ROOT' 的情况)
        let dirSql = "SELECT id, name, modified_at, remote_path FROM directories WHERE (parent_id = ? OR (parent_id IS NULL AND ? = 'ROOT')) AND id != 'ROOT';"
        let dirStmt = try SQLiteStatement(db: db, sql: dirSql)
        dirStmt.bindText(parentId, at: 1)
        dirStmt.bindText(parentId, at: 2)
        
        while dirStmt.step() == SQLITE_ROW {
            let id = dirStmt.columnText(at: 0)
            let name = dirStmt.columnText(at: 1)
            let mtime = Date(timeIntervalSince1970: dirStmt.columnDouble(at: 2))
            
            items.append(VirtualFileItem(
                id: id,
                name: name,
                isDirectory: true,
                size: 0,
                modifiedAt: mtime,
                parentId: parentId,
                remotePath: dirStmt.columnText(at: 3)
            ))
        }
        
        // 2. 查询子文件
        let fileSql = "SELECT id, name, size, modified_at, remote_path FROM files WHERE parent_id = ?;"
        let fileStmt = try SQLiteStatement(db: db, sql: fileSql)
        fileStmt.bindText(parentId, at: 1)
        
        while fileStmt.step() == SQLITE_ROW {
            let id = fileStmt.columnText(at: 0)
            let name = fileStmt.columnText(at: 1)
            let size = fileStmt.columnInt64(at: 2)
            let mtime = Date(timeIntervalSince1970: fileStmt.columnDouble(at: 3))
            
            items.append(VirtualFileItem(
                id: id,
                name: name,
                isDirectory: false,
                size: size,
                modifiedAt: mtime,
                parentId: parentId,
                remotePath: fileStmt.columnText(at: 4)
            ))
        }
        
        return items
    }
}
