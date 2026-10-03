//
//  StorageClientFactory.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  存储客户端统一工厂 - 负责多协议客户端创建与实例化
//

import Foundation
@_exported import CloudDriveContracts
import CloudDriveSupport
import CloudDrivePersistence

/// 统一存储客户端工厂
public class StorageClientFactory {
    
    /// 根据配置创建对应的 StorageClient 实例
    public static func createClient(configuration: StorageConfiguration) -> StorageClient {
        switch configuration {
        case .webdav(let config):
            return WebDAVStorageClient(config: config)
            
        case .s3(let config):
            return S3StorageClient(config: config)
            
        case .smb(let config):
            return SMBStorageClient(config: config)
            
        case .ftp(let config):
            return FTPStorageClient(config: config)
            
        case .pan123(let config):
            return Pan123StorageClient(config: config)
            
        case .local(let config):
            let client = LocalStorageClient()
            if let bookmark = config.bookmarkData {
                client.configureSecurityScope(bookmarkData: bookmark)
            } else if !config.path.isEmpty {
                client.configureSecurityScope(url: URL(fileURLWithPath: config.path))
            }
            return client
        }
    }
    
    /// 根据 VaultInfo 解析并创建对应的 StorageClient 实例 (具备向后兼容性)
    public static func createClient(
        for vault: VaultInfo,
        fallbackPassword: String? = nil
    ) -> StorageClient {
        // 1. 如果包含多协议存储配置，注入有效凭据（防止脱敏存储导致密码丢失）
        if let config = vault.storageConfig {
            let effectiveConfig: StorageConfiguration
            if (config.secret ?? "").isEmpty, let pass = fallbackPassword, !pass.isEmpty {
                effectiveConfig = config.replacingSecret(pass)
            } else {
                effectiveConfig = config
            }
            return createClient(configuration: effectiveConfig)
        }
        
        // 2. 向后兼容：判断是否为 WebDAV
        if let urlStr = vault.webdavURL, !urlStr.isEmpty, let username = vault.webdavUsername {
            let pass = fallbackPassword ?? "local"
            let webdavConfig = WebDAVStorageConfig(baseURL: urlStr, username: username, password: pass)
            return WebDAVStorageClient(config: webdavConfig)
        }
        
        // 3. 向后兼容：判断为本地文件夹
        let localConfig = LocalStorageConfig(path: vault.storagePath, bookmarkData: vault.bookmarkData)
        return createClient(configuration: .local(localConfig))
    }
    
    /// 从 VaultInfo 解析出 StorageConfiguration
    public static func createConfiguration(from vault: VaultInfo, password: String? = nil) -> StorageConfiguration {
        if let config = vault.storageConfig {
            if (config.secret ?? "").isEmpty, let pass = password, !pass.isEmpty {
                return config.replacingSecret(pass)
            }
            return config
        }
        if let urlStr = vault.webdavURL, !urlStr.isEmpty, let username = vault.webdavUsername {
            let pass = password ?? ""
            return .webdav(WebDAVStorageConfig(baseURL: urlStr, username: username, password: pass))
        }
        return .local(LocalStorageConfig(path: vault.storagePath, bookmarkData: vault.bookmarkData))
    }
    
    /// 测试指定协议配置的连接有效性
    public static func testConnection(configuration: StorageConfiguration) async throws -> Bool {
        let client = createClient(configuration: configuration)
        return try await client.testConnection()
    }
}
