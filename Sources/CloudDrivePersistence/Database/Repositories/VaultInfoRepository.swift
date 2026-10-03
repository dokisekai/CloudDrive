import CloudDriveContracts
import CloudDriveSupport
//
//  VaultInfoRepository.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  Vault Info 仓储操作
//

import Foundation
import SQLite3

/// 保险库基本信息仓储
public final class VaultInfoRepository: Sendable {
    private let connection: SQLiteConnection
    
    public init(connection: SQLiteConnection) {
        self.connection = connection
    }
    
    public func saveVaultInfo(vaultId: String, basePath: String) throws {
        guard let db = connection.rawHandle else { throw DatabaseError.notOpened }
        
        try connection.execute(sql: "DELETE FROM vault_info;")
        
        let sql = "INSERT INTO vault_info (vault_id, base_path, created_at) VALUES (?, ?, ?);"
        let stmt = try SQLiteStatement(db: db, sql: sql)
        stmt.bindText(vaultId, at: 1)
        stmt.bindText(basePath, at: 2)
        stmt.bindDouble(Date().timeIntervalSince1970, at: 3)
        
        if stmt.step() != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.stepFailed(sql: sql, code: SQLITE_ERROR, message: msg)
        }
    }
    
    public func getVaultInfo() throws -> (vaultId: String, basePath: String)? {
        guard let db = connection.rawHandle else { throw DatabaseError.notOpened }
        
        let sql = "SELECT vault_id, base_path FROM vault_info LIMIT 1;"
        let stmt = try SQLiteStatement(db: db, sql: sql)
        
        if stmt.step() == SQLITE_ROW {
            let vaultId = stmt.columnText(at: 0)
            let basePath = stmt.columnText(at: 1)
            return (vaultId, basePath)
        }
        return nil
    }
}
