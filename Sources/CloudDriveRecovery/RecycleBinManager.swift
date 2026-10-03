//
//  RecycleBinManager.swift
//  CloudDriveRecovery
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  回收站核心业务逻辑管理器
//

import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CloudDrivePersistence
import CloudDriveCache
import CloudDriveSync
import CloudDriveSystem
import CloudDrivePreview

public final class RecycleBinManager: @unchecked Sendable {
    public static let shared = RecycleBinManager()
    
    private let store: RecycleBinStore
    private let fileManager = FileManager.default
    
    public init(store: RecycleBinStore = .shared) {
        self.store = store
    }
    
    /// 回收站本地备份目录
    private func backupDirectory(for vaultId: String) -> URL {
        let dir = CloudDrivePaths.sharedDirectory
            .appendingPathComponent("RecycleBinCache", isDirectory: true)
            .appendingPathComponent(vaultId, isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    
    // MARK: - 软删除移入回收站
    
    /// 将文件/目录软删除移动到回收站
    @discardableResult
    public func moveToTrash(
        item: VirtualFileItem,
        vaultId: String,
        vfs: (any RecycleBinVFSDelegate)? = nil,
        cacheManager: CacheManager? = nil
    ) async throws -> RecycleBinItem {
        let itemId = UUID().uuidString
        var backupPath: String? = nil
        
        // 1. 如果本地存在已下载的缓存文件且开启了快照，备份到回收站缓存目录
        if !item.isDirectory, RecycleBinConfig.isLocalSnapshotEnabled, let cacheManager = cacheManager {
            let cachedURL = cacheManager.localPath(for: item.id)
            if fileManager.fileExists(atPath: cachedURL.path) {
                let backupDir = backupDirectory(for: vaultId)
                let destURL = backupDir.appendingPathComponent("\(itemId)_\(item.name)")
                do {
                    if copyfile(cachedURL.path, destURL.path, nil, copyfile_flags_t(COPYFILE_CLONE)) != 0 {
                        try fileManager.copyItem(at: cachedURL, to: destURL)
                    }
                    backupPath = destURL.path
                } catch {
                    Logger.shared.warning(.fileOps, "RecycleBin: Failed to backup cached file for \(item.name): \(error)")
                }
            }
        }
        
        // 2. 构造并持久化回收站元数据
        let binItem = RecycleBinItem(
            id: itemId,
            vaultId: vaultId,
            fileId: item.id,
            name: item.name,
            originalParentId: item.parentId,
            originalRemotePath: item.remotePath ?? "",
            isDirectory: item.isDirectory,
            size: item.size,
            deletedAt: Date(),
            localBackupPath: backupPath
        )
        try store.save(binItem)
        
        // 3. 从 VFS 本地数据库移出，使 Finder 目录不再展示该文件
        vfs?.deleteFromLocalDatabaseOnly(itemId: item.id)
        vfs?.markPendingDelete(file: item)
        
        // 4. 清除活动缓存
        if item.isDirectory {
            cacheManager?.removeDirectoryCache(forDirectoryPrefix: item.id)
        } else {
            try? cacheManager?.removeCachedFile(fileId: item.id)
        }
        ThumbnailManager.shared.invalidate(fileId: item.id)
        
        Logger.shared.info(.fileOps, "🗑️ RecycleBin: Item successfully soft-deleted: \(item.name) (ID: \(item.id))")
        return binItem
    }
    
    // MARK: - 还原文件
    
    /// 从回收站还原文件或目录
    @discardableResult
    public func restore(
        id: String,
        vfs: any RecycleBinVFSDelegate,
        syncManager: SyncManager,
        cacheManager: CacheManager? = nil
    ) async throws -> VirtualFileItem {
        guard let binItem = try store.getItem(id: id) else {
            throw VFSError.fileNotFound
        }
        
        // 1. 验证目标父目录是否存在；若已被删除则回退恢复至根目录 ROOT
        var targetParentId = binItem.originalParentId
        if targetParentId != "ROOT" && targetParentId != "/" {
            let parentExists = (try? vfs.getItem(id: targetParentId)) != nil
            if !parentExists {
                targetParentId = "ROOT"
                Logger.shared.info(.fileOps, "RecycleBin: Original parent missing, restoring to ROOT")
            }
        }
        
        // 2. 检查目标目录下是否存在同名冲突项（优先检查本地已有记录）
        var finalName = binItem.name
        let existingChildren: [VirtualFileItem]
        if let localChildren = vfs.listLocalChildren(parentId: targetParentId), !localChildren.isEmpty {
            existingChildren = localChildren
        } else {
            existingChildren = (try? vfs.listDirectory(directoryId: targetParentId)) ?? []
        }
        let isSameDestination = (targetParentId == binItem.originalParentId)
        let isCollisionWithOther: (VirtualFileItem) -> Bool = { child in
            guard child.name == finalName else { return false }
            if isSameDestination && (child.id == binItem.fileId || child.remotePath == binItem.originalRemotePath) {
                return false
            }
            return true
        }
        
        if existingChildren.contains(where: isCollisionWithOther) {
            let ext = (finalName as NSString).pathExtension
            let base = (finalName as NSString).deletingPathExtension
            var counter = 1
            while existingChildren.contains(where: isCollisionWithOther) {
                if ext.isEmpty {
                    finalName = "\(base) (\(counter))"
                } else {
                    finalName = "\(base) (\(counter)).\(ext)"
                }
                counter += 1
            }
        }
        
        let effectiveFileId: String
        let effectiveRemotePath: String
        if finalName != binItem.name {
            let resolved = vfs.resolveRestoredRemotePath(finalName: finalName, targetParentId: targetParentId, isDirectory: binItem.isDirectory)
            effectiveRemotePath = resolved.remotePath
            effectiveFileId = resolved.fileId
        } else {
            effectiveFileId = binItem.fileId
            effectiveRemotePath = binItem.originalRemotePath
        }
        
        // 3. 在 VFS 中重新记录本地元数据
        if binItem.isDirectory {
            vfs.recordOfflineDirectory(
                id: effectiveFileId,
                name: finalName,
                parentId: targetParentId,
                remotePath: effectiveRemotePath
            )
        } else {
            vfs.recordOfflineFile(
                id: effectiveFileId,
                name: finalName,
                parentId: targetParentId,
                size: binItem.size,
                remotePath: effectiveRemotePath
            )
        }
        
        // 失效目录缓存以使下次展示即刻生效
        vfs.invalidateDirectoryCache(directoryId: targetParentId)
        
        // 4. 若有本地备份缓存，恢复至 CacheManager
        if let backupPath = binItem.localBackupPath, fileManager.fileExists(atPath: backupPath), let cacheManager = cacheManager {
            let backupURL = URL(fileURLWithPath: backupPath)
            try? cacheManager.cacheFile(fileId: effectiveFileId, from: backupURL, policy: .automatic)
            try? fileManager.removeItem(at: backupURL)
        }
        
        // 5. 更新同步元数据
        let needsReupload = (finalName != binItem.name)
        if needsReupload && effectiveFileId != binItem.fileId {
            syncManager.removeMetadata(fileId: binItem.fileId)
        }
        syncManager.updateMetadata(FileMetadata(
            fileId: effectiveFileId,
            name: finalName,
            parentId: targetParentId,
            isDirectory: binItem.isDirectory,
            syncStatus: needsReupload ? .pendingUpload : .synced,
            remotePath: effectiveRemotePath,
            size: binItem.size,
            localModifiedAt: Date(),
            remoteModifiedAt: Date(),
            downloadProgress: 1.0
        ))
        
        if needsReupload, !binItem.isDirectory {
            // 若发生冲突更名且有本地备份内容，调度上传新文件
            let localCachePath = cacheManager?.localPath(for: effectiveFileId).path ?? ""
            if fileManager.fileExists(atPath: localCachePath) {
                vfs.scheduleRestoredUpload(fileId: effectiveFileId, fileName: finalName, parentId: targetParentId, localPath: localCachePath, remotePath: effectiveRemotePath, vaultId: binItem.vaultId)
            }
        }
        
        // 6. 从回收站数据库中移除记录
        try store.delete(id: id)
        
        // 7. 发送文件变更通知与信号
        FileProviderSync.shared.notifyFileChanged(vaultId: binItem.vaultId, fileId: effectiveFileId)
        
        let restoredItem = VirtualFileItem(
            id: effectiveFileId,
            name: finalName,
            isDirectory: binItem.isDirectory,
            size: binItem.size,
            modifiedAt: Date(),
            parentId: targetParentId,
            syncStatus: needsReupload ? .pendingUpload : .synced,
            localPath: cacheManager?.localPath(for: effectiveFileId).path,
            remotePath: effectiveRemotePath
        )
        Logger.shared.info(.fileOps, "♻️ RecycleBin: Item restored: \(finalName) (ID: \(effectiveFileId)) to parent \(targetParentId)")
        return restoredItem
    }
    
    // MARK: - 彻底删除
    
    /// 彻底删除单项（从云端真正移除）
    public func deletePermanently(
        id: String,
        vfs: (any RecycleBinVFSDelegate)? = nil,
        syncManager: SyncManager? = nil,
        storageClient: StorageClient? = nil
    ) async throws {
        guard let binItem = try store.getItem(id: id) else { return }
        
        // 1. 清理本地备份文件
        if let backupPath = binItem.localBackupPath, fileManager.fileExists(atPath: backupPath) {
            try? fileManager.removeItem(atPath: backupPath)
        }
        
        // 2. 调度云端真正删除
        if let syncManager = syncManager {
            try? syncManager.enqueuePersistent(.deleteItem(
                fileId: binItem.fileId,
                remotePath: binItem.originalRemotePath,
                isDirectory: binItem.isDirectory,
                directoryId: binItem.isDirectory && (vfs?.isEncrypted == true) ? binItem.fileId : nil,
                vaultId: binItem.vaultId
            ))
        } else if let storageClient = storageClient, !binItem.originalRemotePath.isEmpty {
            try? await storageClient.delete(path: binItem.originalRemotePath)
        }
        
        // 3. 从数据库中彻底删除
        syncManager?.removeMetadata(fileId: binItem.fileId)
        try store.delete(id: id)
        Logger.shared.info(.fileOps, "🔥 RecycleBin: Item permanently deleted: \(binItem.name)")
    }
    
    // MARK: - 清空回收站
    
    /// 清空指定存储库或全部回收站
    public func emptyTrash(
        vaultId: String? = nil,
        vfs: (any RecycleBinVFSDelegate)? = nil,
        syncManager: SyncManager? = nil,
        storageClient: StorageClient? = nil
    ) async throws {
        let items = try store.listItems(vaultId: vaultId)
        for item in items {
            try await deletePermanently(
                id: item.id,
                vfs: vfs,
                syncManager: syncManager,
                storageClient: storageClient
            )
        }
        Logger.shared.info(.fileOps, "🧹 RecycleBin: Trash emptied for vault: \(vaultId ?? "all") (Total \(items.count) items)")
    }
    
    // MARK: - 自动过期清理与级联注销
    
    /// 执行自动过期清理（根据 RecycleBinConfig.retentionDays 清理过期项）
    @discardableResult
    public func purgeExpiredItems(
        vfs: (any RecycleBinVFSDelegate)? = nil,
        syncManager: SyncManager? = nil,
        storageClient: StorageClient? = nil
    ) async -> Int {
        let retention = RecycleBinConfig.retentionDays
        guard retention > 0 else { return 0 } // 0 为永久保留
        
        let cutoffDate = Date().addingTimeInterval(-Double(retention) * 86400.0)
        guard let expired = try? store.getExpiredItems(before: cutoffDate), !expired.isEmpty else {
            return 0
        }
        
        Logger.shared.info(.fileOps, "⏳ RecycleBin: Found \(expired.count) expired items (retention: \(retention) days), purging...")
        var count = 0
        for item in expired {
            do {
                try await deletePermanently(
                    id: item.id,
                    vfs: vfs,
                    syncManager: syncManager,
                    storageClient: storageClient
                )
                count += 1
            } catch {
                Logger.shared.warning(.fileOps, "RecycleBin: Failed to purge expired item \(item.name): \(error)")
            }
        }
        return count
    }
    
    /// 当删除保险库时级联清理该库的所有回收站元数据和本地磁盘备份
    public func purgeVaultData(vaultId: String) {
        do {
            try store.deleteByVault(vaultId: vaultId)
            let backupDir = backupDirectory(for: vaultId)
            if fileManager.fileExists(atPath: backupDir.path) {
                try? fileManager.removeItem(at: backupDir)
            }
            RecycleBinConfig.resetToGlobal(for: vaultId)
            Logger.shared.info(.fileOps, "🧹 RecycleBin: Successfully purged all recycle bin data for deleted vault \(vaultId)")
        } catch {
            Logger.shared.warning(.fileOps, "RecycleBin: Failed to purge data for vault \(vaultId): \(error)")
        }
    }
    
    // MARK: - 查询接口
    
    public func listItems(vaultId: String? = nil) -> [RecycleBinItem] {
        (try? store.listItems(vaultId: vaultId)) ?? []
    }
    
    public func count(vaultId: String? = nil) -> Int {
        (try? store.count(vaultId: vaultId)) ?? 0
    }
    
    public func totalSize(vaultId: String? = nil) -> Int64 {
        (try? store.totalSize(vaultId: vaultId)) ?? 0
    }
}
