//
//  CacheManager.swift
//  CloudDriveCache
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  本地缓存管理器门面 - 向后兼容适配层
//

import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit

/// 缓存管理器 (向后兼容门面，底层由模块化 CacheService 驱动)
public class CacheManager: ConflictContentAccess {
    public static let shared = CacheManager()
    private static let scopedLock = NSLock()
    private static var scoped: [String: CacheManager] = [:]

    public static func forVault(_ vaultId: String) -> CacheManager {
        scopedLock.lock()
        defer { scopedLock.unlock() }
        if let manager = scoped[vaultId] { return manager }
        // Vault storage uses a stable, collision-resistant path supplied by CloudDrivePaths.
        let root = CloudDrivePaths.vaultDirectory(for: vaultId).appendingPathComponent("Cache", isDirectory: true)
        let service = CacheService(
            storage: CacheDiskStorage(cacheDirectory: root.appendingPathComponent("Files", isDirectory: true)),
            metadataStore: CacheMetadataStore(metadataURL: root.appendingPathComponent("metadata.json")),
            notifier: CacheNotificationService(vaultId: vaultId),
            vaultId: vaultId
        )
        let manager = CacheManager(service: service)
        scoped[vaultId] = manager
        return manager
    }
    
    private let service: CacheService
    public var vaultId: String? { service.vaultId }
    
    public typealias CachePolicy = CloudDriveCache.CachePolicy
    public typealias CacheMetadata = CloudDriveCache.CacheMetadata
    
    public init(service: CacheService = CacheService.shared) {
        self.service = service
    }
    
    /// 用户可配置的最大缓存上限（默认 10GB）
    public var maxCacheSize: Int64 {
        get { service.maxCacheSize }
        set { service.maxCacheSize = newValue }
    }
    
    public func beginAccess(fileId: String) { service.beginAccess(fileId: fileId) }
    public func endAccess(fileId: String) { service.endAccess(fileId: fileId) }
    public func effectivePolicy(fileId: String) -> CachePolicy { service.effectivePolicy(fileId: fileId) }

    public func reconcileCache() {
        service.reconciler.reconcile()
    }
    
    public func localPath(for fileId: String) -> URL {
        service.localPath(for: fileId)
    }
    
    public func isCached(fileId: String) -> Bool {
        service.isCached(fileId: fileId)
    }
    
    public func cacheFile(fileId: String, data: Data, policy: CachePolicy = .automatic) throws {
        try service.cacheFile(fileId: fileId, data: data, policy: policy)
    }
    
    public func cacheFile(fileId: String, from sourceURL: URL, policy: CachePolicy = .automatic) throws {
        try service.cacheFile(fileId: fileId, from: sourceURL, policy: policy)
    }
    
    public func postCacheEvictionNotification(fileId: String?) {
        service.notifier.postEvictionNotification(fileId: fileId)
    }
    
    public func evictFile(fileId: String) throws {
        try service.evictFile(fileId: fileId)
    }
    
    public func updateLastAccessed(fileId: String) {
        service.updateLastAccessed(fileId: fileId)
    }
    
    public func setCachePolicy(fileId: String, policy: CachePolicy) {
        service.setCachePolicy(fileId: fileId, policy: policy)
    }
    
    public func getAllPinnedFileIds() -> [String] {
        service.getAllPinnedFileIds()
    }
    
    public func pinFile(fileId: String) {
        service.pinFile(fileId: fileId)
    }
    
    public func unpinFile(fileId: String) {
        service.unpinFile(fileId: fileId)
    }
    
    public func getCacheMetadata(fileId: String) -> CacheMetadata? {
        service.getCacheMetadata(fileId: fileId)
    }
    
    public func getAllCachedFileIds() -> [String] {
        service.getAllCachedFileIds()
    }
    
    public func getCacheStatistics() -> (totalSize: Int64, fileCount: Int) {
        service.getCacheStatistics()
    }
    
    public func readCachedFile(fileId: String) throws -> Data {
        try service.readCachedFile(fileId: fileId)
    }
    
    public func removeCachedFile(fileId: String) throws {
        try service.removeCachedFile(fileId: fileId)
    }
    
    public func moveCache(from oldFileId: String, to newFileId: String) throws {
        try service.moveCache(from: oldFileId, to: newFileId)
    }
    
    public func moveDirectoryCache(from oldDirId: String, to newDirId: String) {
        service.moveDirectoryCache(from: oldDirId, to: newDirId)
    }
    
    public func removeDirectoryCache(forDirectoryPrefix dirPrefix: String) {
        service.removeDirectoryCache(forDirectoryPrefix: dirPrefix)
    }
    
    public func cloneCache(from sourceFileId: String, to destinationFileId: String) throws {
        try service.cloneCache(from: sourceFileId, to: destinationFileId)
    }
    
    public func clearAllCache() throws {
        try service.clearAllCache()
    }
    
    public func currentCacheSize() -> Int64 {
        service.currentCacheSize()
    }
    
    public func cleanupIfNeeded() throws {
        try service.cleanupIfNeeded()
    }
    
    // MARK: - Multi-Vault Aggregations
    
    /// 计算全部存储库（及全局共享缓存）的缓存总大小
    public static func totalCacheSizeAcrossAllVaults(knownVaultIds: [String] = []) -> Int64 {
        var total: Int64 = 0
        var evaluatedVaultIds = Set<String>()
        var evaluatedDigestDirs = Set<String>()
        
        // 1. 已知保险库 ID
        for vaultId in knownVaultIds {
            evaluatedVaultIds.insert(vaultId)
            let digest = SHA256.hash(data: Data(vaultId.utf8)).map { String(format: "%02x", $0) }.joined()
            evaluatedDigestDirs.insert(digest)
            total += CacheManager.forVault(vaultId).currentCacheSize()
        }
        
        // 2. 内存中已创建的 scoped 保险库
        scopedLock.lock()
        let scopedVaultIds = Array(scoped.keys)
        scopedLock.unlock()
        for vaultId in scopedVaultIds where !evaluatedVaultIds.contains(vaultId) {
            evaluatedVaultIds.insert(vaultId)
            let digest = SHA256.hash(data: Data(vaultId.utf8)).map { String(format: "%02x", $0) }.joined()
            evaluatedDigestDirs.insert(digest)
            total += CacheManager.forVault(vaultId).currentCacheSize()
        }
        
        // 3. 扫描磁盘上其它未被以上代码实例化的 Vault 目录
        let vaultsDir = CloudDrivePaths.sharedDirectory.appendingPathComponent("Vaults", isDirectory: true)
        if let contents = try? FileManager.default.contentsOfDirectory(at: vaultsDir, includingPropertiesForKeys: nil) {
            let fm = FileManager.default
            for dir in contents {
                let dirName = dir.lastPathComponent
                guard !evaluatedDigestDirs.contains(dirName) else { continue }
                let cacheDir = dir.appendingPathComponent("Cache", isDirectory: true)
                guard fm.fileExists(atPath: cacheDir.path) else { continue }
                
                let filesDir = cacheDir.appendingPathComponent("Files", isDirectory: true)
                let storage = CacheDiskStorage(cacheDirectory: filesDir)
                total += storage.totalDiskSize()
            }
        }
        
        // 4. 全局共享缓存
        total += CacheManager.shared.currentCacheSize()
        
        return total
    }
    
    /// 清理全部存储库（及全局共享缓存）的本地缓存
    public static func clearAllCacheAcrossAllVaults(knownVaultIds: [String] = []) throws {
        var clearedVaultIds = Set<String>()
        var clearedDigestDirs = Set<String>()
        
        for vaultId in knownVaultIds {
            clearedVaultIds.insert(vaultId)
            let digest = SHA256.hash(data: Data(vaultId.utf8)).map { String(format: "%02x", $0) }.joined()
            clearedDigestDirs.insert(digest)
            try? CacheManager.forVault(vaultId).clearAllCache()
        }
        
        scopedLock.lock()
        let scopedVaultIds = Array(scoped.keys)
        scopedLock.unlock()
        for vaultId in scopedVaultIds where !clearedVaultIds.contains(vaultId) {
            clearedVaultIds.insert(vaultId)
            let digest = SHA256.hash(data: Data(vaultId.utf8)).map { String(format: "%02x", $0) }.joined()
            clearedDigestDirs.insert(digest)
            try? CacheManager.forVault(vaultId).clearAllCache()
        }
        
        // 磁盘上遗留的未关联 Vault 目录
        let vaultsDir = CloudDrivePaths.sharedDirectory.appendingPathComponent("Vaults", isDirectory: true)
        if let contents = try? FileManager.default.contentsOfDirectory(at: vaultsDir, includingPropertiesForKeys: nil) {
            let fm = FileManager.default
            for dir in contents {
                let dirName = dir.lastPathComponent
                guard !clearedDigestDirs.contains(dirName) else { continue }
                let cacheDir = dir.appendingPathComponent("Cache", isDirectory: true)
                guard fm.fileExists(atPath: cacheDir.path) else { continue }
                let filesDir = cacheDir.appendingPathComponent("Files", isDirectory: true)
                let storage = CacheDiskStorage(cacheDirectory: filesDir)
                try? storage.clearAll()
            }
        }
        
        try? CacheManager.shared.clearAllCache()
    }
    
    /// 获取全部存储库的固定文件 ID 集合
    public static func allPinnedFileIdsAcrossAllVaults(knownVaultIds: [String] = []) -> [String] {
        var allPinned: [String] = []
        var evaluatedVaultIds = Set<String>()
        
        for vaultId in knownVaultIds {
            evaluatedVaultIds.insert(vaultId)
            allPinned.append(contentsOf: CacheManager.forVault(vaultId).getAllPinnedFileIds())
        }
        
        scopedLock.lock()
        let scopedVaultIds = Array(scoped.keys)
        scopedLock.unlock()
        for vaultId in scopedVaultIds where !evaluatedVaultIds.contains(vaultId) {
            evaluatedVaultIds.insert(vaultId)
            allPinned.append(contentsOf: CacheManager.forVault(vaultId).getAllPinnedFileIds())
        }
        
        allPinned.append(contentsOf: CacheManager.shared.getAllPinnedFileIds())
        return allPinned
    }
    
    /// 取消全部存储库中所有固定的文件
    public static func unpinAllAcrossAllVaults(knownVaultIds: [String] = []) {
        var evaluatedVaultIds = Set<String>()
        
        for vaultId in knownVaultIds {
            evaluatedVaultIds.insert(vaultId)
            let mgr = CacheManager.forVault(vaultId)
            for fileId in mgr.getAllPinnedFileIds() {
                mgr.unpinFile(fileId: fileId)
            }
        }
        
        scopedLock.lock()
        let scopedVaultIds = Array(scoped.keys)
        scopedLock.unlock()
        for vaultId in scopedVaultIds where !evaluatedVaultIds.contains(vaultId) {
            evaluatedVaultIds.insert(vaultId)
            let mgr = CacheManager.forVault(vaultId)
            for fileId in mgr.getAllPinnedFileIds() {
                mgr.unpinFile(fileId: fileId)
            }
        }
        
        let sharedMgr = CacheManager.shared
        for fileId in sharedMgr.getAllPinnedFileIds() {
            sharedMgr.unpinFile(fileId: fileId)
        }
    }
}