//
//  CacheService.swift
//  CloudDriveCache
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  缓存统一门面服务 (Cache Facade)
//

import Foundation
import CloudDriveContracts
import CloudDriveSupport
import Darwin
import CryptoKit

extension CacheService {
    public func localPath(for fileId: String) -> URL {
        storage.localPath(for: fileId)
    }

    public func isCached(fileId: String) -> Bool {
        storage.exists(fileId: fileId)
    }

    public func cacheFile(fileId: String, data: Data, policy: CachePolicy = .automatic) throws {
        beginAccess(fileId: fileId)
        defer { endAccess(fileId: fileId) }
        try storage.write(data: data, for: fileId)
        
        let existingPolicy = metadataStore.get(for: fileId)?.policy
        let effectivePolicy: CachePolicy = (policy == .automatic && existingPolicy == .pinned) ? .pinned : policy
        
        metadataStore.set(CacheMetadata(
            fileId: fileId,
            size: Int64(data.count),
            downloadedAt: Date(),
            lastAccessedAt: Date(),
            policy: effectivePolicy
        ))
        metadataStore.save(immediate: true)
        
        try cleanupIfNeeded()
    }

    public func cacheFile(fileId: String, from sourceURL: URL, policy: CachePolicy = .automatic) throws {
        beginAccess(fileId: fileId)
        defer { endAccess(fileId: fileId) }
        let size = try storage.cache(from: sourceURL, for: fileId)
        
        let existingPolicy = metadataStore.get(for: fileId)?.policy
        let effectivePolicy: CachePolicy = (policy == .automatic && existingPolicy == .pinned) ? .pinned : policy
        
        metadataStore.set(CacheMetadata(
            fileId: fileId,
            size: size,
            downloadedAt: Date(),
            lastAccessedAt: Date(),
            policy: effectivePolicy
        ))
        metadataStore.save(immediate: true)
        
        Logger.shared.success(.cache, "File cached: \(fileId)")
        Logger.shared.info(.cache, "Size: \(size) bytes, policy: \(effectivePolicy.rawValue)")
        
        try cleanupIfNeeded()
    }

    public func readCachedFile(fileId: String) throws -> Data {
        try storage.read(fileId: fileId)
    }

    public func removeCachedFile(fileId: String) throws {
        try storage.remove(fileId: fileId)
        _ = metadataStore.remove(for: fileId)
        metadataStore.save(immediate: true)
        
        if var meta = syncManager.getMetadata(fileId: fileId) {
            if meta.syncStatus == .synced {
                meta.syncStatus = .cloudOnly
                meta.downloadProgress = 0.0
                syncManager.updateMetadata(meta)
            }
        }
        notifier.postEvictionNotification(fileId: fileId)
    }

    public func moveCache(from oldFileId: String, to newFileId: String) throws {
        try storage.move(from: oldFileId, to: newFileId)
        
        if let oldMeta = metadataStore.remove(for: oldFileId) {
            metadataStore.set(CacheMetadata(
                fileId: newFileId,
                size: oldMeta.size,
                downloadedAt: oldMeta.downloadedAt,
                lastAccessedAt: Date(),
                policy: oldMeta.policy
            ))
            metadataStore.save(immediate: true)
        }
        Logger.shared.info(.cache, "Moved cache: \(oldFileId) -> \(newFileId)")
    }

    public func moveDirectoryCache(from oldDirId: String, to newDirId: String) {
        try? storage.moveDirectory(from: oldDirId, to: newDirId)
        
        let oldPrefix = oldDirId.hasSuffix("/") ? oldDirId : "\(oldDirId)/"
        let newPrefix = newDirId.hasSuffix("/") ? newDirId : "\(newDirId)/"
        
        let allMetas = metadataStore.getAllMetadata()
        for (key, oldMeta) in allMetas where key.hasPrefix(oldPrefix) {
            _ = metadataStore.remove(for: key)
            let newKey = key.replacingOccurrences(of: oldPrefix, with: newPrefix)
            metadataStore.set(CacheMetadata(
                fileId: newKey,
                size: oldMeta.size,
                downloadedAt: oldMeta.downloadedAt,
                lastAccessedAt: Date(),
                policy: oldMeta.policy
            ))
        }
        metadataStore.save(immediate: true)
        Logger.shared.info(.cache, "Moved directory cache: \(oldDirId) -> \(newDirId)")
    }

    public func removeDirectoryCache(forDirectoryPrefix dirPrefix: String) {
        try? storage.removeDirectory(forDirectoryPrefix: dirPrefix)
        let removedKeys = metadataStore.removePrefix(dirPrefix)
        
        if !removedKeys.isEmpty {
            metadataStore.save(immediate: true)
            for key in removedKeys {
                if var meta = syncManager.getMetadata(fileId: key) {
                    if meta.syncStatus == .synced {
                        meta.syncStatus = .cloudOnly
                        meta.downloadProgress = 0.0
                        syncManager.updateMetadata(meta)
                    }
                }
                notifier.postEvictionNotification(fileId: key)
            }
            Logger.shared.info(.cache, "Purged directory cache for prefix: \(dirPrefix), removed \(removedKeys.count) items")
        }
    }

    public func cloneCache(from sourceFileId: String, to destinationFileId: String) throws {
        try storage.clone(from: sourceFileId, to: destinationFileId)
        if let srcMeta = metadataStore.get(for: sourceFileId) {
            metadataStore.set(CacheMetadata(
                fileId: destinationFileId,
                size: srcMeta.size,
                downloadedAt: Date(),
                lastAccessedAt: Date(),
                policy: srcMeta.policy
            ))
            metadataStore.save(immediate: true)
        }
        Logger.shared.info(.cache, "Cloned cache: \(sourceFileId) -> \(destinationFileId)")
    }
}
