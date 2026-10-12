//
//  VirtualFileSystem.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  虚拟文件系统 - 类似 Cryptomator 的架构
//  在本地维护文件结构映射，WebDAV 只存储加密数据
//

import Foundation
import CryptomatorCryptoLib


/// 虚拟文件系统管理器
public class VirtualFileSystem: SyncVaultAccess {
    public static let shared = VirtualFileSystem()
    
    public internal(set) var database: VFSDatabase
    public internal(set) var cryptomatorFormat: CryptomatorFormat?
    let encryption: VFSEncryption
    var storageClient: StorageClient? {
        didSet {
            guard let client = storageClient, let provider = activeProvider, provider.vaultId == currentVaultId else { return }
            syncManager.configure(storageClient: client, vfs: self)
        }
    }
    
    // 同步管理器
    public var syncManager: SyncManager {
        currentVaultId.map { SyncManager.forVault($0) } ?? .shared
    }
    
    // Cache manager
    public var cacheManager: CacheManager {
        currentVaultId.map { CacheManager.forVault($0) } ?? .shared
    }
    
    // 操作管理器
    let operationManager = FileOperationManager.shared
    
    // 当前保险库 ID，用于密钥链访问
    public var currentVaultId: String? {
        didSet {
            if oldValue != currentVaultId {
                if let oldValue { SyncManager.forVault(oldValue).activeVFS = nil }
                activeProvider = nil
                isEncryptedVault = false
                isDirectMappingVault = false
            }
        }
    }
    public var vaultId: String? { return currentVaultId }
    
    // 是否为加密保险库模式
    var isEncryptedVault: Bool = false
    public var isEncrypted: Bool { return isEncryptedVault }
    
    // 是否为直接映射 WebDAV 模式
    var isDirectMappingVault: Bool = false
    public var isDirectMapping: Bool { return isDirectMappingVault }
    
    // 活跃驱动提供者
    public internal(set) var activeProvider: VFSProvider? {
        didSet {
            guard let provider = activeProvider, provider.vaultId == currentVaultId,
                  let client = storageClient else { return }
            isEncryptedVault = provider.isEncrypted
            isDirectMappingVault = !provider.isEncrypted
            syncManager.configure(storageClient: client, vfs: self)
        }
    }
    
    // 虚拟根目录 ID
    let rootId = "ROOT"
    
    // Directory DB cache TTL management (45s default avoids redundant network calls, auto background refresh upon expiration)
    var directoryCacheTimestamps: [String: Date] = [:]
    let directoryCacheLock = NSLock()
    let directoryCacheTTL: TimeInterval = 45.0
    
    public init(vaultId: String? = nil) {
        self.currentVaultId = vaultId
        self.database = VFSDatabase(vaultId: vaultId)
        self.encryption = VFSEncryption()
    }
    
    public func configureStorage(client: StorageClient) {
        self.storageClient = client
        print("✅ [VFS] Custom storage client configured successfully")
    }
    
    /// 获取当前配置的 storageClient
    public func getStorageClient() -> StorageClient? {
        return storageClient
    }
    
}

// MARK: - ThumbnailRemoteSyncDelegate Conformance
extension VirtualFileSystem: ThumbnailRemoteSyncDelegate {
    public func listDirectoryForThumbnails(directoryId: String) async throws -> [VirtualFileItem] {
        return try await listDirectoryFromWebDAVAsync(directoryId: directoryId)
    }
    public func downloadThumbnailFile(fileId: String, to destinationURL: URL) async throws {
        _ = try await downloadFile(fileId: fileId, to: destinationURL)
    }
    public func uploadThumbnailFile(localURL: URL, name: String, parentId: String) async throws {
        _ = try await uploadFile(localURL: localURL, name: name, parentId: parentId)
    }
}

// MARK: - VaultIgnoreVFSDelegate Conformance
extension VirtualFileSystem: VaultIgnoreVFSDelegate {}
