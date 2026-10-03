//
//  SyncService.swift
//  CloudDriveSync
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  同步子系统统一门面服务
//

import Foundation
import CloudDriveContracts

extension SyncService {
    struct QueueResult {
        var etag: String? = nil
        var remotePath: String? = nil
        var replacement: VirtualFileItem? = nil
        var stagedPath: String? = nil
        var deleted = false
    }

    static func isConflict(_ error: Error) -> Bool {
        if let syncError = error as? SyncError, case .conflictDetected = syncError { return true }
        if let storageError = error as? StorageError, case .serverError(let code, _) = storageError { return code == 412 }
        return false
    }

    static func isAuthError(_ error: Error) -> Bool {
        if let storageError = error as? StorageError, case .serverError(let code, _) = storageError {
            return code == 401 || code == 403
        }
        if case WebDAVError.serverError(let code) = error {
            return code == 401 || code == 403
        }
        if let vfsError = error as? VFSError {
            switch vfsError {
            case .invalidPassword, .vaultLocked: return true
            default: return false
            }
        }
        return false
    }

    static func isPermanentError(_ error: Error, retryCount: Int) -> Bool {
        if let storageError = error as? StorageError {
            switch storageError {
            case .serverError(let code, _):
                return code == 400 || code == 405 || code == 413
            default:
                break
            }
        }
        if retryCount >= 10 {
            return true
        }
        return false
    }

    func processQueueItem(_ item: SyncQueueItem) async throws -> QueueResult {
        try validate(item)
        let snapshot = contextLock.withLock { (storageClient, configuredVFS) }
        guard let storageClient = snapshot.0 else { throw SyncError.storageNotConfigured }
        let vfs = snapshot.1
        var result = QueueResult()
        switch item.operation {
        case .upload(let fileId, let localPath, let remotePath):
            guard fileManager.fileExists(atPath: localPath) else { throw SyncError.operationFailed("Pending upload content is missing") }
            result.etag = try await storageClient.uploadFile(localURL: URL(fileURLWithPath: localPath), to: remotePath, expectedETag: item.expectedETag) { _ in }
            result.remotePath = remotePath
            result.stagedPath = stagedPath(localPath)
            // Read the current metadata only after the request; a later edit may
            // have changed the local content and must keep its pending status.
            if getMetadata(fileId: fileId) == nil {
                try metadataStore.updateMetadataPersistent(FileMetadata(fileId: fileId, name: URL(fileURLWithPath: remotePath).lastPathComponent, parentId: (remotePath as NSString).deletingLastPathComponent, isDirectory: false, syncStatus: .pendingUpload, remotePath: remotePath))
            }
        case .encryptedUpload(_, let name, let parentId, let localPath, let operationVault):
            guard let vfs, vfs.isEncrypted, vfs.vaultId == operationVault else { throw SyncError.operationFailed("The target encrypted vault is not unlocked") }
            guard fileManager.fileExists(atPath: localPath) else { throw SyncError.operationFailed("Pending upload content is missing") }
            let uploaded = try await vfs.uploadFile(localURL: URL(fileURLWithPath: localPath), name: name, parentId: parentId, expectedETag: item.expectedETag)
            guard vfs.vaultId == operationVault else { throw SyncError.operationFailed("The vault changed during upload; the original edit is retained") }
            vfs.reconcileOfflineItem(oldId: item.operation.fileId, item: uploaded)
            result.etag = uploaded.etag
            result.remotePath = uploaded.remotePath
            result.replacement = uploaded
            result.stagedPath = stagedPath(localPath)
        case .download(let fileId, let remotePath, let localPath):
            let url = URL(fileURLWithPath: localPath)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await storageClient.downloadFile(path: remotePath, to: url) { progress in
                try? self.metadataStore.mutateMetadata(fileId: fileId) { metadata in
                    metadata.downloadProgress = progress
                    metadata.syncStatus = .downloading
                }
            }
            try metadataStore.mutateMetadata(fileId: fileId) { metadata in
                metadata.localPath = localPath
                metadata.downloadProgress = 1
            }
            result.remotePath = remotePath
        case .delete(let fileId, let remotePath):
            let effectivePath = (metadataStore.getMetadata(fileId: fileId)?.remotePath) ?? remotePath
            if let vfs, vfs.isEncrypted {
                do { try await vfs.deleteRemoteItem(remotePath: effectivePath, directoryId: nil) }
                catch StorageError.notFound { }
                vfs.deleteFromLocalDatabaseOnly(itemId: fileId)
            } else {
                do { try await storageClient.delete(path: effectivePath) }
                catch StorageError.notFound { }
            }
            removeMetadata(fileId: fileId)
            result.deleted = true
        case .deleteItem(let fileId, let remotePath, let isDirectory, let directoryId, let operationVault):
            let effectivePath = (metadataStore.getMetadata(fileId: fileId)?.remotePath) ?? remotePath
            if let vfs {
                guard vfs.vaultId == operationVault else { throw SyncError.operationFailed("The deletion belongs to another vault") }
                do { try await vfs.deleteRemoteItem(remotePath: effectivePath, directoryId: directoryId) }
                catch StorageError.notFound { }
                guard vfs.vaultId == operationVault else { throw SyncError.operationFailed("The vault changed during deletion") }
                vfs.deleteFromLocalDatabaseOnly(itemId: fileId)
            } else {
                guard directoryId == nil else { throw SyncError.operationFailed("The encrypted deletion target is unavailable") }
                do { try await storageClient.delete(path: effectivePath) }
                catch StorageError.notFound { }
            }
            if isDirectory { removeDirectoryMetadata(forDirectoryPrefix: fileId) }
            else { removeMetadata(fileId: fileId) }
            result.deleted = true
        case .createDirectory(let directoryId, let name, let parentId, let remotePath):
            if let vfs, vfs.isEncrypted {
                let created = try await vfs.createDirectory(name: name, parentId: parentId, directoryId: directoryId)
                result.replacement = created
                result.remotePath = created.remotePath
            } else {
                try await storageClient.createDirectory(path: remotePath)
                result.remotePath = remotePath
                try metadataStore.mutateMetadata(fileId: directoryId) { $0.syncStatus = .pendingUpload }
            }
        case .encryptedCreateDirectory(let directoryId, let name, let parentId, _, let operationVault):
            guard let vfs, vfs.isEncrypted, vfs.vaultId == operationVault else { throw SyncError.operationFailed("The target encrypted vault is not unlocked") }
            let created = try await vfs.createDirectory(name: name, parentId: parentId, directoryId: directoryId)
            guard vfs.vaultId == operationVault else { throw SyncError.operationFailed("The vault changed during directory creation") }
            result.replacement = created
            result.remotePath = created.remotePath
        case .move(_, let source, let target):
            try await storageClient.move(from: source, to: target)
            result.remotePath = target
        }
        return result
    }

    func stagedPath(_ path: String) -> String? {
        // Only journal-owned staging files may be removed after confirmation.
        let scopedStaging = queue.persistenceURL.deletingLastPathComponent().appendingPathComponent("pending_uploads").standardizedFileURL.path + "/"
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        return normalized.hasPrefix(scopedStaging) ? normalized : nil
    }


}
