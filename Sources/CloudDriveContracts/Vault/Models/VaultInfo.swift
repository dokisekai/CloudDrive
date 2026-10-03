//
//  VaultInfo.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  保险库信息模型与配置结构
//

import Foundation

/// 保险库信息
public struct VaultInfo: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let storagePath: String
    public let createdAt: Date
    
    // 多协议存储类型与配置
    public var storageType: StorageType
    public var storageConfig: StorageConfiguration?
    
    // WebDAV 配置（向后兼容）
    public var webdavURL: String?
    public var webdavUsername: String?
    
    // 挂载状态（不持久化，运行时状态）
    public var isMounted: Bool = false
    
    // 是否为加密保险库
    public var isEncrypted: Bool = false
    
    // 本地文件夹安全书签（用于沙箱跨进程访问）
    public var bookmarkData: Data? = nil
    
    // 是否在启动时自动挂载（默认 true）
    public var isAutoMount: Bool = true
    
    // 显式 public 初始化器
    public init(
        id: String,
        name: String,
        storagePath: String,
        createdAt: Date,
        storageType: StorageType = .webdav,
        storageConfig: StorageConfiguration? = nil,
        webdavURL: String? = nil,
        webdavUsername: String? = nil,
        isMounted: Bool = false,
        isEncrypted: Bool = false,
        bookmarkData: Data? = nil,
        isAutoMount: Bool = true
    ) {
        self.id = id
        self.name = name
        self.storagePath = storagePath
        self.createdAt = createdAt
        self.storageType = storageType
        self.storageConfig = storageConfig
        self.webdavURL = webdavURL
        self.webdavUsername = webdavUsername
        self.isMounted = isMounted
        self.isEncrypted = isEncrypted
        self.bookmarkData = bookmarkData
        self.isAutoMount = isAutoMount
    }
    
    /// 是否为本地保险库（非云端 WebDAV/S3/SMB/FTP）
    public var isLocal: Bool {
        if storageType == .local { return true }
        if let config = storageConfig, case .local = config { return true }
        return (webdavURL == nil || webdavURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true) && storageConfig == nil
    }
    
    // 自定义 Codable 实现，排除 isMounted
    enum CodingKeys: String, CodingKey {
        case id, name, storagePath, createdAt, storageType, storageConfig, webdavURL, webdavUsername, isEncrypted, bookmarkData, isAutoMount
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        storagePath = try container.decode(String.self, forKey: .storagePath)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        webdavURL = try container.decodeIfPresent(String.self, forKey: .webdavURL)
        webdavUsername = try container.decodeIfPresent(String.self, forKey: .webdavUsername)
        isEncrypted = (try? container.decode(Bool.self, forKey: .isEncrypted)) ?? false
        bookmarkData = try? container.decodeIfPresent(Data.self, forKey: .bookmarkData)
        isAutoMount = (try? container.decodeIfPresent(Bool.self, forKey: .isAutoMount)) ?? true
        isMounted = false  // 默认未挂载
        
        let decodedType = try? container.decodeIfPresent(StorageType.self, forKey: .storageType)
        let decodedConfig = try? container.decodeIfPresent(StorageConfiguration.self, forKey: .storageConfig)
        
        self.storageConfig = decodedConfig
        if let type = decodedType {
            self.storageType = type
        } else if let config = decodedConfig {
            self.storageType = config.type
        } else if webdavURL != nil && !(webdavURL?.isEmpty ?? true) {
            self.storageType = .webdav
        } else {
            self.storageType = .local
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(storagePath, forKey: .storagePath)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(storageType, forKey: .storageType)
        try container.encodeIfPresent(storageConfig?.withoutSecrets, forKey: .storageConfig)
        try container.encodeIfPresent(webdavURL, forKey: .webdavURL)
        try container.encodeIfPresent(webdavUsername, forKey: .webdavUsername)
        try container.encode(isEncrypted, forKey: .isEncrypted)
        try container.encodeIfPresent(bookmarkData, forKey: .bookmarkData)
        try container.encode(isAutoMount, forKey: .isAutoMount)
        // 不编码 isMounted
    }
    
    // Hashable conformance
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    public static func == (lhs: VaultInfo, rhs: VaultInfo) -> Bool {
        lhs.id == rhs.id
    }
}

/// 保险库配置
public struct VaultConfig: Codable, Sendable {
    public let vaultId: String
    public let version: Int
    public let cipherCombo: String
    public let createdAt: Date
    public let salt: Data
    
    public init(vaultId: String, version: Int, cipherCombo: String, createdAt: Date, salt: Data) {
        self.vaultId = vaultId
        self.version = version
        self.cipherCombo = cipherCombo
        self.createdAt = createdAt
        self.salt = salt
    }
}

/// 目录元数据
public struct DirectoryMetadata: Codable, Sendable {
    public let name: String
    
    public init(name: String) {
        self.name = name
    }
}

/// 保险库配置（无加密）
public struct VaultConfigNoEncryption: Codable, Sendable {
    public let vaultId: String
    public let version: Int
    public let encrypted: Bool
    public let createdAt: Date
    
    public init(vaultId: String, version: Int, encrypted: Bool, createdAt: Date) {
        self.vaultId = vaultId
        self.version = version
        self.encrypted = encrypted
        self.createdAt = createdAt
    }
}
