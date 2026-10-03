import CloudDriveContracts
import CloudDriveSupport
//
//  DatabaseColumn.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  数据库字段名强类型枚举
//

import Foundation

/// 数据库列统一协议
public protocol DatabaseColumnProtocol: RawRepresentable where RawValue == String {
    var table: DatabaseTable { get }
}

/// vault_info 字段
public enum VaultInfoColumn: String, DatabaseColumnProtocol, Sendable {
    case id         = "id"
    case vaultId    = "vault_id"
    case basePath   = "base_path"
    case createdAt  = "created_at"
    
    public var table: DatabaseTable { .vaultInfo }
}

/// directories 字段
public enum DirectoryColumn: String, DatabaseColumnProtocol, Sendable {
    case id           = "id"
    case name         = "name"
    case parentId     = "parent_id"
    case encryptedId  = "encrypted_id"
    case remotePath   = "remote_path"
    case createdAt    = "created_at"
    case modifiedAt   = "modified_at"
    
    public var table: DatabaseTable { .directories }
}

/// files 字段
public enum FileColumn: String, DatabaseColumnProtocol, Sendable {
    case id            = "id"
    case name          = "name"
    case parentId      = "parent_id"
    case size          = "size"
    case encryptedName = "encrypted_name"
    case remotePath    = "remote_path"
    case createdAt     = "created_at"
    case modifiedAt    = "modified_at"
    
    public var table: DatabaseTable { .files }
}
