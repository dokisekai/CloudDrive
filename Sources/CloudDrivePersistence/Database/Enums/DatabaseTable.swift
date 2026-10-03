import CloudDriveContracts
import CloudDriveSupport
//
//  DatabaseTable.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  数据库表名强类型枚举
//

import Foundation

/// SQLite 数据库表枚举
public enum DatabaseTable: String, CaseIterable, Sendable {
    case vaultInfo   = "vault_info"
    case directories = "directories"
    case files         = "files"
    case vaultSettings = "vault_settings"
    
    /// 获取建表与索引 DDL SQL
    public var createSchemaStatements: [String] {
        switch self {
        case .vaultInfo:
            return [
                """
                CREATE TABLE IF NOT EXISTS vault_info (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    vault_id TEXT NOT NULL,
                    base_path TEXT NOT NULL,
                    created_at REAL NOT NULL
                );
                """
            ]
        case .directories:
            return [
                """
                CREATE TABLE IF NOT EXISTS directories (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    parent_id TEXT,
                    encrypted_id TEXT NOT NULL,
                    remote_path TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    modified_at REAL NOT NULL
                );
                """,
                "CREATE INDEX IF NOT EXISTS idx_directories_parent ON directories(parent_id);"
            ]
        case .files:
            return [
                """
                CREATE TABLE IF NOT EXISTS files (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    parent_id TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    encrypted_name TEXT NOT NULL,
                    remote_path TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    modified_at REAL NOT NULL
                );
                """,
                "CREATE INDEX IF NOT EXISTS idx_files_parent ON files(parent_id);"
            ]
        case .vaultSettings:
            return [
                """
                CREATE TABLE IF NOT EXISTS vault_settings (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL,
                    updated_at REAL NOT NULL
                );
                """
            ]
        }
    }
}
