import CloudDriveContracts
import CloudDriveSupport
//
//  DatabaseError.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  数据库结构化错误枚举
//

import Foundation

/// 结构化数据库错误类型
public enum DatabaseError: Error, LocalizedError, Sendable {
    case notOpened
    case connectionFailed(path: String, code: Int32, message: String)
    case prepareFailed(sql: String, code: Int32, message: String)
    case stepFailed(sql: String, code: Int32, message: String)
    case recordNotFound(table: DatabaseTable, id: String)
    case corrupted(path: String, backupPath: String?)
    
    public var errorDescription: String? {
        switch self {
        case .notOpened:
            return "数据库未打开"
        case .connectionFailed(let path, let code, let msg):
            return "数据库连接失败 [\(path)]: (\(code)) \(msg)"
        case .prepareFailed(let sql, let code, let msg):
            return "SQL 预编译失败 [\(sql)]: (\(code)) \(msg)"
        case .stepFailed(let sql, let code, let msg):
            return "SQL 执行失败 [\(sql)]: (\(code)) \(msg)"
        case .recordNotFound(let table, let id):
            return "数据未找到 [表 \(table.rawValue), ID: \(id)]"
        case .corrupted(let path, let backup):
            return "数据库损坏 [\(path)], 备份至: \(backup ?? "无")"
        }
    }
}
