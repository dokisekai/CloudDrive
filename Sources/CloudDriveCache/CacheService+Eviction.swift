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
    public func evictFile(fileId: String) throws {
        guard !isProtected(fileId: fileId) else { throw CocoaError(.fileWriteNoPermission) }
        guard try withEvictionLease(fileId: fileId, { try removeCachedFile(fileId: fileId) }) else { throw CocoaError(.fileWriteNoPermission) }
        if var meta = syncManager.getMetadata(fileId: fileId) {
            meta.syncStatus = .cloudOnly
            meta.downloadProgress = 0.0
            syncManager.updateMetadata(meta)
        }
        notifier.postEvictionNotification(fileId: fileId)
    }

    public func clearAllCache() throws {
        for meta in metadataStore.getAllMetadata().values where !isProtected(fileId: meta.fileId) {
            _ = try withEvictionLease(fileId: meta.fileId, { try storage.remove(fileId: meta.fileId) })
        }
        // 清理磁盘上可能存在的未登记文件
        let diskFiles = storage.listAllDiskFiles()
        for diskFile in diskFiles where !isProtected(fileId: diskFile) {
            _ = try withEvictionLease(fileId: diskFile, { try? storage.remove(fileId: diskFile) })
        }
        // Clear clean content while retaining pin intent and pending local edits.
        for meta in metadataStore.getAllMetadata().values where !isProtected(fileId: meta.fileId) && !storage.exists(fileId: meta.fileId) {
            _ = metadataStore.remove(for: meta.fileId)
        }
        metadataStore.save(immediate: true)
        
        // 清理 CAS 去重池中的孤立 Blobs
        storage.pruneBlobs()
        
        let allMetas = syncManager.getAllMetadata()
        for var meta in allMetas where meta.syncStatus == .synced && !storage.exists(fileId: meta.fileId) {
            meta.syncStatus = .cloudOnly
            meta.downloadProgress = 0.0
            syncManager.updateMetadata(meta)
        }
        notifier.postEvictionNotification(fileId: nil)
    }

    public func currentCacheSize() -> Int64 {
        let metaSize = getCacheStatistics().totalSize
        let diskSize = storage.totalDiskSize()
        return max(metaSize, diskSize)
    }

    public func cleanupIfNeeded() throws {
        let stats = getCacheStatistics()
        if stats.totalSize > maxCacheSize {
            Logger.shared.warning(.cache, "Cache size exceeded: \(stats.totalSize) / \(maxCacheSize) bytes")
            let targetSize = maxCacheSize * 8 / 10
            
            // 采用分批增量 LRU 扫描，优先处理最旧候选对象，免除全表级联查询与全量内存反序列化
            let candidates = metadataStore.getEvictionCandidates(limit: 100)
            
            var cleanedCount = 0
            var cleanedSize: Int64 = 0
            
            for item in candidates {
                if stats.totalSize - cleanedSize <= targetSize {
                    break
                }
                if !isProtected(fileId: item.fileId), storage.exists(fileId: item.fileId) {
                    do {
                        guard try withEvictionLease(fileId: item.fileId, {
                            try storage.remove(fileId: item.fileId)
                            _ = metadataStore.remove(for: item.fileId)
                        }) else { continue }
                        cleanedSize += item.size
                        cleanedCount += 1
                        
                        if var meta = syncManager.getMetadata(fileId: item.fileId) {
                            meta.syncStatus = .cloudOnly
                            meta.downloadProgress = 0.0
                            syncManager.updateMetadata(meta)
                        }
                        notifier.postEvictionNotification(fileId: item.fileId)
                        Logger.shared.info(.cache, "Cleaned file: \(item.fileId), size: \(item.size) bytes")
                    } catch {
                        Logger.shared.error(.cache, "Failed to clean file: \(item.fileId), error: \(error)")
                    }
                }
            }
            
            metadataStore.save(immediate: true)
            Logger.shared.success(.cache, "Cache cleanup completed: freed \(cleanedSize) bytes, \(cleanedCount) files")
        }
    }
}
