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
        try removeCachedFile(fileId: fileId)
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
        for meta in metadataStore.getAllMetadata().values where !storage.exists(fileId: meta.fileId) {
            _ = try withEvictionLease(fileId: meta.fileId, { _ = metadataStore.remove(for: meta.fileId) })
        }
        metadataStore.save(immediate: true)

        // 清理 CAS 去重池中的孤立 Blobs
        storage.pruneBlobs()
        
        notifier.postEvictionNotification(fileId: nil)
    }

    public func currentCacheSize() -> Int64 {
        let metaSize = getCacheStatistics().totalSize
        let diskSize = storage.totalDiskSize()
        return max(metaSize, diskSize)
    }

    public func cleanupIfNeeded() throws {
        let mode: CacheManagementMode = configuredMaximumSize != nil ? .fixed : AppSettings.shared.cacheManagementMode
        let needsCleanup: Bool
        let targetFreeBytes: Int64
        
        switch mode {
        case .smart:
            let diskSpace = DiskSpaceHelper.currentDiskSpace(at: storage.cacheDirectory)
            let minFreePercent = Double(AppSettings.shared.smartFreeSpacePercentage)
            if diskSpace.totalBytes > 0 && diskSpace.freePercentage < minFreePercent {
                let requiredAvailable = Int64(Double(diskSpace.totalBytes) * (minFreePercent / 100.0))
                let deficit = requiredAvailable - diskSpace.availableBytes
                targetFreeBytes = max(deficit, 100 * 1024 * 1024)
                needsCleanup = true
                Logger.shared.warning(.cache, "Smart Cache: Mac disk free space is low (\(String(format: "%.1f", diskSpace.freePercentage))% < \(Int(minFreePercent))%). Deficit to free: \(targetFreeBytes) bytes")
            } else {
                needsCleanup = false
                targetFreeBytes = 0
            }
        case .fixed:
            let dynamicStats = getDynamicCacheStatistics()
            if dynamicStats.totalSize > maxCacheSize {
                targetFreeBytes = dynamicStats.totalSize - (maxCacheSize * 8 / 10)
                needsCleanup = true
                Logger.shared.warning(.cache, "Fixed Cache: Dynamic cache size exceeded (\(dynamicStats.totalSize) > \(maxCacheSize) bytes). Target to free: \(targetFreeBytes) bytes")
            } else {
                needsCleanup = false
                targetFreeBytes = 0
            }
        }
        
        guard needsCleanup && targetFreeBytes > 0 else { return }
        
        // 采用分批增量 LRU 扫描，只处理非 pinned 候选对象（temporary 优先，随后 automatic 按最久未访问排序）
        let candidates = metadataStore.getEvictionCandidates(limit: 100)
        
        var cleanedCount = 0
        var cleanedSize: Int64 = 0
        
        for item in candidates {
            if cleanedSize >= targetFreeBytes {
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
                    
                    notifier.postEvictionNotification(fileId: item.fileId)
                    Logger.shared.info(.cache, "Cleaned dynamic cache file: \(item.fileId), size: \(item.size) bytes")
                } catch {
                    Logger.shared.error(.cache, "Failed to clean dynamic cache file: \(item.fileId), error: \(error)")
                }
            }
        }
        
        metadataStore.save(immediate: true)
        Logger.shared.success(.cache, "Cache cleanup completed: freed \(cleanedSize) bytes, \(cleanedCount) files")
    }
}
