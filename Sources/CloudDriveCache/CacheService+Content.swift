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
        try withPublicationLease(fileId: fileId) {
            try storage.write(data: data, for: fileId)
            try? contentIndex.remove(fileId)
            
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
            
        }
        try cleanupIfNeeded()
    }

    public func cacheFile(fileId: String, from sourceURL: URL, policy: CachePolicy = .automatic, confirmedETag: String? = nil) throws {
        beginAccess(fileId: fileId)
        defer { endAccess(fileId: fileId) }
        try withPublicationLease(fileId: fileId) {
            var contentHash: String?
            let size = try storage.cache(from: sourceURL, for: fileId, onHashedContent: { contentHash = $0 })
            if let contentHash {
                let metadata = try? syncManager.getMetadataPersistent(fileId: fileId)
                let generation = metadata?.syncStatus == .pendingUpload && metadata?.localPath == sourceURL.path ? metadata?.localModifiedAt?.timeIntervalSince1970 : nil
                try? contentIndex.record(fileId: fileId, hash: contentHash, etag: confirmedETag, generation: generation, url: storage.localPath(for: fileId))
            } else { try? contentIndex.remove(fileId) }
            
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
            
        }
        try cleanupIfNeeded()
    }

    public func readCachedFile(fileId: String) throws -> Data {
        try storage.read(fileId: fileId)
    }

    public func removeCachedFile(fileId: String) throws {
        guard try withEvictionLease(fileId: fileId, {
            try storage.remove(fileId: fileId)
            try? contentIndex.remove(fileId)
            _ = metadataStore.remove(for: fileId)
            metadataStore.save(immediate: true)
        }) else { throw CocoaError(.fileWriteNoPermission) }
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

    public func moveDirectoryCache(from oldDirId: String, to newDirId: String) throws {
        try storage.moveDirectory(from: oldDirId, to: newDirId)
        
        let oldPrefix = oldDirId.hasSuffix("/") ? oldDirId : "\(oldDirId)/"
        let newPrefix = newDirId.hasSuffix("/") ? newDirId : "\(newDirId)/"
        
        let allMetas = metadataStore.getAllMetadata()
        for (key, oldMeta) in allMetas where key.hasPrefix(oldPrefix) {
            _ = metadataStore.remove(for: key)
            let newKey = newPrefix + key.dropFirst(oldPrefix.count)
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
        let normalized = dirPrefix.hasPrefix("/") ? dirPrefix : "/" + dirPrefix
        let prefix = normalized.hasSuffix("/") ? normalized : normalized + "/"
        let candidates = Set(storage.listAllDiskFiles() + Array(metadataStore.getAllMetadata().keys))
        for key in candidates {
            let canonical = key.hasPrefix("/") ? key : "/" + key
            guard canonical == normalized || canonical.hasPrefix(prefix) else { continue }
            do { try removeCachedFile(fileId: key) }
            catch { Logger.shared.warning(.cache, "Retaining protected directory cache: \(key)") }
        }
    }

    public func cloneCache(from sourceFileId: String, to destinationFileId: String, confirmedETag: String? = nil) throws {
        beginAccess(fileId: sourceFileId)
        beginAccess(fileId: destinationFileId)
        defer { endAccess(fileId: destinationFileId); endAccess(fileId: sourceFileId) }
        try withPublicationLeases(fileIds: [sourceFileId, destinationFileId]) {
            try storage.clone(from: sourceFileId, to: destinationFileId)
            if let source = try? contentIndex.get(sourceFileId), contentIndex.matches(source, url: storage.localPath(for: sourceFileId)) {
                try? contentIndex.record(fileId: destinationFileId, hash: source.hash, etag: confirmedETag, generation: nil, url: storage.localPath(for: destinationFileId))
            } else { try? contentIndex.remove(destinationFileId) }
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
}
