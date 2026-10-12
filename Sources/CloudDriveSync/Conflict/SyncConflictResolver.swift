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
import Darwin
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
        let (metadata, originalUploadIds) = try syncManager.withJournalCommit {
            guard let metadata = syncManager.getMetadata(fileId: fileId) else {
                throw SyncError.operationFailed("File metadata not found for conflict resolution: \(fileId)")
            }
            let uploads = try syncManager.queue.itemsForFilePersistent(fileId: fileId).filter {
                switch $0.operation { case .upload, .encryptedUpload: return true; default: return false }
            }
            // Do not cancel or replace a payload while its network transfer can
            // still commit after this resolution. Resolve only suspended work.
            if strategy != .promptUser, uploads.contains(where: {
                $0.startedAt != nil || !($0.blockedByConflict == true || $0.isPermanentFailure == true || $0.isAuthFailure == true)
            }) {
                throw SyncError.operationFailed("Wait for the active sync operation to finish before resolving its conflict")
            }
            return (metadata, uploads.map(\.id))
        }
        func persistRestored(_ restored: FileMetadata, downloaded: URL, publishTo target: URL) throws {
            try syncManager.withJournalCommit {
                let newerOperations = try syncManager.queue.itemsForFilePersistent(fileId: fileId).contains {
                    $0.operation.fileId == fileId && !originalUploadIds.contains($0.id)
                }
                let current = syncManager.getMetadata(fileId: fileId)
                let metadataUnchanged = current?.localPath == metadata.localPath && current?.localModifiedAt == metadata.localModifiedAt
                if !newerOperations && metadataUnchanged {
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard rename(downloaded.path, target.path) == 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    try syncManager.updateMetadataPersistent(restored)
                }
                try syncManager.queue.removeItemsPersistent(ids: originalUploadIds)
            }
        }
        func durableCopy(_ source: String, to destination: URL) throws {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if copyfile(source, destination.path, nil, copyfile_flags_t(COPYFILE_CLONE)) != 0 {
                try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: destination)
            }
            let copied = try FileHandle(forWritingTo: destination)
            defer { try? copied.close() }
            try copied.synchronize()
            let fd = open(destination.deletingLastPathComponent().path, O_RDONLY)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        switch strategy {
        case .localWins:
            // 本地胜出：以当前远端版本为条件上传，避免覆盖后续编辑
            var updated = metadata
            updated.syncStatus = .pendingUpload
            guard let localPath = metadata.localPath, FileManager.default.fileExists(atPath: localPath) else {
                throw SyncError.operationFailed("Conflict content is missing; original operation retained")
            }
            guard let remotePath = metadata.remotePath else {
                throw SyncError.operationFailed("Conflict remote path is missing")
            }
            let parent = (remotePath as NSString).deletingLastPathComponent
            let remote = try await storageClient.listDirectory(path: parent.isEmpty ? "/" : parent)
            guard let revision = remote.first(where: { $0.path == remotePath })?.etag, !revision.isEmpty else {
                throw SyncError.operationFailed("Cannot safely replace a remote file without its current ETag")
            }
            let staged = syncManager.queue.persistenceURL.deletingLastPathComponent().appendingPathComponent("pending_uploads").appendingPathComponent(UUID().uuidString)
            try durableCopy(localPath, to: staged)
            updated.localPath = staged.path
            updated.etag = revision
            try syncManager.withJournalCommit {
                let newer = try syncManager.queue.itemsForFilePersistent(fileId: fileId).contains {
                    $0.operation.fileId == fileId && !originalUploadIds.contains($0.id)
                }
                guard !newer,
                      syncManager.getMetadata(fileId: fileId)?.localPath == metadata.localPath,
                      syncManager.getMetadata(fileId: fileId)?.localModifiedAt == metadata.localModifiedAt else {
                    throw SyncError.operationFailed("A newer local edit arrived during conflict resolution")
                }
                try syncManager.updateMetadataPersistent(updated)
                let operation: SyncOperation
                if let vfs, vfs.isEncrypted, let vaultId = vfs.vaultId {
                    operation = .encryptedUpload(fileId: fileId, fileName: metadata.name, parentId: metadata.parentId, localPath: staged.path, vaultId: vaultId)
                } else {
                    operation = .upload(fileId: fileId, localPath: staged.path, remotePath: remotePath)
                }
                _ = try syncManager.queue.enqueuePersistent(operation, expectedETag: revision, vaultId: syncManager.vaultId)
                try syncManager.queue.removeItemsPersistent(ids: originalUploadIds)
            }
            syncManager.processSyncQueue()
            
        case .remoteWins:
            // 远端胜出：丢弃本地修改，重新拉取远端文件
            let targetURL = cacheManager.localPath(for: fileId)
            try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let downloadedURL = targetURL.deletingLastPathComponent().appendingPathComponent("restore-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: downloadedURL) }
            if let vfs = vfs, vfs.isEncrypted {
                guard let remotePath = metadata.remotePath else { throw SyncError.operationFailed("Conflict remote path is missing") }
                let downloadedETag = try await vfs.downloadConflictContent(fileId: fileId, remotePath: remotePath, to: downloadedURL)
                var updated = metadata
                updated.etag = downloadedETag
                updated.localPath = targetURL.path
                updated.syncStatus = .synced
                updated.lastSyncTime = Date()
                try persistRestored(updated, downloaded: downloadedURL, publishTo: targetURL)
            } else if let remotePath = metadata.remotePath {
                let downloadedETag = try await storageClient.downloadFile(path: remotePath, to: downloadedURL, expectedETag: nil) { _ in }
                var updated = metadata
                updated.etag = downloadedETag
                updated.localPath = targetURL.path
                updated.syncStatus = .synced
                updated.lastSyncTime = Date()
                try persistRestored(updated, downloaded: downloadedURL, publishTo: targetURL)
            }
            guard vfs?.isEncrypted == true || metadata.remotePath != nil else {
                throw SyncError.operationFailed("Conflict remote path is missing")
            }
            try syncManager.queue.removeItemsPersistent(ids: originalUploadIds)
            
        case .forkBothWithSuffix:
            // 分叉保留两份：保留云端版本，将本地版本另存为副本并上传
            let ext = (metadata.name as NSString).pathExtension
            let baseName = (metadata.name as NSString).deletingPathExtension
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HHmmss"
            let dateStr = formatter.string(from: Date()) + "_" + UUID().uuidString.prefix(8)
            let conflictFileName = ext.isEmpty ? "\(baseName) (Conflicted Copy \(dateStr))" : "\(baseName) (Conflicted Copy \(dateStr)).\(ext)"
            
            if let currentLocal = metadata.localPath, FileManager.default.fileExists(atPath: currentLocal) {
                if let vfs = vfs, vfs.isEncrypted, let vaultId = vfs.vaultId {
                    let conflictFileId = "pending_\(UUID().uuidString)"
                    let conflictLocalURL = syncManager.queue.persistenceURL.deletingLastPathComponent().appendingPathComponent("pending_uploads").appendingPathComponent(UUID().uuidString)
                    try durableCopy(currentLocal, to: conflictLocalURL)
                    let conflictMeta = FileMetadata(
                        fileId: conflictFileId,
                        name: conflictFileName,
                        parentId: metadata.parentId,
                        isDirectory: metadata.isDirectory,
                        syncStatus: .pendingUpload,
                        localPath: conflictLocalURL.path,
                        remotePath: nil,
                        size: metadata.size,
                        localModifiedAt: Date(),
                        lastSyncTime: nil
                    )
                    try syncManager.updateMetadataPersistent(conflictMeta)
                    try syncManager.enqueuePersistent(.encryptedUpload(
                        fileId: conflictFileId,
                        fileName: conflictFileName,
                        parentId: metadata.parentId,
                        localPath: conflictLocalURL.path,
                        vaultId: vaultId
                    ))
                } else {
                    let parentDir = metadata.remotePath.map { ($0 as NSString).deletingLastPathComponent } ?? "/"
                    let conflictRemotePath = parentDir == "/" ? "/\(conflictFileName)" : "\(parentDir)/\(conflictFileName)"
                    let conflictFileId = conflictRemotePath
                    let conflictLocalURL = syncManager.queue.persistenceURL.deletingLastPathComponent().appendingPathComponent("pending_uploads").appendingPathComponent(UUID().uuidString)
                    try durableCopy(currentLocal, to: conflictLocalURL)
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
                    try syncManager.updateMetadataPersistent(conflictMeta)
                    try syncManager.enqueuePersistent(.upload(fileId: conflictFileId, localPath: conflictLocalURL.path, remotePath: conflictRemotePath))
                }
            }
            
            else {
                throw SyncError.operationFailed("Conflict content is missing; original operation retained")
            }
            // 恢复原文件的远端版本
            let originalCacheURL = cacheManager.localPath(for: fileId)
            try FileManager.default.createDirectory(at: originalCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let downloadedURL = originalCacheURL.deletingLastPathComponent().appendingPathComponent("restore-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: downloadedURL) }
            if let vfs = vfs, vfs.isEncrypted {
                guard let remotePath = metadata.remotePath else { throw SyncError.operationFailed("Conflict remote path is missing") }
                let downloadedETag = try await vfs.downloadConflictContent(fileId: fileId, remotePath: remotePath, to: downloadedURL)
                var originalMeta = metadata
                originalMeta.etag = downloadedETag
                originalMeta.localPath = originalCacheURL.path
                originalMeta.syncStatus = .synced
                originalMeta.lastSyncTime = Date()
                try persistRestored(originalMeta, downloaded: downloadedURL, publishTo: originalCacheURL)
            } else if let remotePath = metadata.remotePath {
                let downloadedETag = try await storageClient.downloadFile(path: remotePath, to: downloadedURL, expectedETag: nil) { _ in }
                var originalMeta = metadata
                originalMeta.etag = downloadedETag
                originalMeta.localPath = originalCacheURL.path
                originalMeta.syncStatus = .synced
                originalMeta.lastSyncTime = Date()
                try persistRestored(originalMeta, downloaded: downloadedURL, publishTo: originalCacheURL)
            }
            // 清理旧冲突上传队列项，避免原文件与远端再次产生冲突
            guard vfs?.isEncrypted == true || metadata.remotePath != nil else {
                throw SyncError.operationFailed("Conflict remote path is missing")
            }
            try syncManager.queue.removeItemsPersistent(ids: originalUploadIds)
            syncManager.processSyncQueue()
            
        case .promptUser:
            // 保持冲突状态，等待用户在界面或访达中选择处理策略
            var updated = metadata
            updated.syncStatus = .conflict
            try syncManager.updateMetadataPersistent(updated)
            if let vaultId = vfs?.vaultId ?? syncManager.vaultId {
                FileProviderSync.shared.notifyFileChanged(vaultId: vaultId, fileId: fileId)
            }
        }
    }
}
