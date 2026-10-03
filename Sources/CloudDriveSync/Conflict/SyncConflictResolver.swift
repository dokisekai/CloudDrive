//
//  SyncConflictResolver.swift
//  CloudDriveSync
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  双向修改冲突检测与决议算法
//

import Foundation
import CloudDriveContracts
import CloudDriveSystem

/// 冲突决议器
public final class SyncConflictResolver: Sendable {
    public init() {}
    
    /// 检测冲突
    public func detectConflict(local: FileMetadata, remote: StorageResource) -> SyncConflictType {
        guard let localMod = local.localModifiedAt,
              let remoteMod = remote.lastModified else {
            return .none
        }
        
        if let lastSync = local.lastSyncTime {
            // 本地与远端都在上次同步之后发生过修改
            if localMod > lastSync && remoteMod > lastSync {
                return .bothModified(localMod: localMod, remoteMod: remoteMod)
            }
        } else {
            // 没有上次同步记录，如果 ETag 或大小不同，判定为双向修改冲突
            if let remoteETag = remote.etag, let localETag = local.etag, remoteETag != localETag {
                return .bothModified(localMod: localMod, remoteMod: remoteMod)
            }
            if local.size != remote.contentLength {
                return .bothModified(localMod: localMod, remoteMod: remoteMod)
            }
        }
        return .none
    }
    
    /// 执行冲突解决策略
    public func resolveConflict(
        fileId: String,
        strategy: SyncConflictStrategy,
        storageClient: StorageClient,
        vfs: (any SyncVaultAccess)?,
        syncManager: SyncManager,
        cacheManager: any ConflictContentAccess
    ) async throws {
        guard let metadata = syncManager.getMetadata(fileId: fileId) else {
            throw SyncError.operationFailed("File metadata not found for conflict resolution: \(fileId)")
        }
        
        switch strategy {
        case .localWins:
            // 本地胜出：无条件上传本地修改，覆盖远端
            var updated = metadata
            updated.syncStatus = .pendingUpload
            updated.etag = nil
            syncManager.updateMetadata(updated)
            if let localPath = metadata.localPath, let remotePath = metadata.remotePath {
                try syncManager.enqueuePersistent(.upload(fileId: fileId, localPath: localPath, remotePath: remotePath))
            }
            syncManager.processSyncQueue()
            
        case .remoteWins:
            // 远端胜出：丢弃本地修改，重新拉取远端文件
            if let remotePath = metadata.remotePath {
                let targetURL = cacheManager.localPath(for: fileId)
                try await storageClient.downloadFile(path: remotePath, to: targetURL) { _ in }
                var updated = metadata
                updated.syncStatus = .synced
                updated.lastSyncTime = Date()
                syncManager.updateMetadata(updated)
            }
            syncManager.queue.removeItem(id: fileId)
            
        case .forkBothWithSuffix:
            // 分叉保留两份：保留云端版本，将本地版本另存为副本并上传
            let ext = (metadata.name as NSString).pathExtension
            let baseName = (metadata.name as NSString).deletingPathExtension
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HHmmss"
            let dateStr = formatter.string(from: Date())
            let conflictFileName = ext.isEmpty ? "\(baseName) (Conflicted Copy \(dateStr))" : "\(baseName) (Conflicted Copy \(dateStr)).\(ext)"
            
            let parentDir = metadata.remotePath.map { ($0 as NSString).deletingLastPathComponent } ?? "/"
            let conflictRemotePath = parentDir == "/" ? "/\(conflictFileName)" : "\(parentDir)/\(conflictFileName)"
            let conflictFileId = conflictRemotePath
            
            if let currentLocal = metadata.localPath, FileManager.default.fileExists(atPath: currentLocal) {
                let conflictLocalURL = cacheManager.localPath(for: conflictFileId)
                let destParent = conflictLocalURL.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: destParent, withIntermediateDirectories: true)
                if copyfile(currentLocal, conflictLocalURL.path, nil, copyfile_flags_t(COPYFILE_CLONE)) != 0 {
                    try? FileManager.default.copyItem(at: URL(fileURLWithPath: currentLocal), to: conflictLocalURL)
                }
                
                let conflictMeta = FileMetadata(
                    fileId: conflictFileId,
                    name: conflictFileName,
                    parentId: metadata.parentId,
                    isDirectory: metadata.isDirectory,
                    syncStatus: .pendingUpload,
                    localPath: conflictLocalURL.path,
                    remotePath: conflictRemotePath,
                    size: metadata.size,
                    localModifiedAt: Date(),
                    lastSyncTime: nil
                )
                syncManager.updateMetadata(conflictMeta)
                try syncManager.enqueuePersistent(.upload(fileId: conflictFileId, localPath: conflictLocalURL.path, remotePath: conflictRemotePath))
            }
            
            // 恢复原文件的远端版本
            if let remotePath = metadata.remotePath {
                let originalCacheURL = cacheManager.localPath(for: fileId)
                try? await storageClient.downloadFile(path: remotePath, to: originalCacheURL) { _ in }
                var originalMeta = metadata
                originalMeta.syncStatus = .synced
                originalMeta.lastSyncTime = Date()
                syncManager.updateMetadata(originalMeta)
            }
            syncManager.processSyncQueue()
            
        case .promptUser:
            // 保持冲突状态，等待用户在界面或访达中选择处理策略
            var updated = metadata
            updated.syncStatus = .conflict
            syncManager.updateMetadata(updated)
            if let vaultId = vfs?.vaultId ?? syncManager.vaultId {
                FileProviderSync.shared.notifyFileChanged(vaultId: vaultId, fileId: fileId)
            }
        }
    }
}
