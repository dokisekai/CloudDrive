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
import CloudDriveSystem

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

    static func isLockError(_ error: Error) -> Bool {
        if let vfsError = error as? VFSError, case .vaultLocked = vfsError {
            return true
        }
        if let syncError = error as? SyncError, case .operationFailed(let msg) = syncError {
            if msg.contains("not unlocked") || msg.contains("locked") {
                return true
            }
        }
        let desc = error.localizedDescription.lowercased()
        if desc.contains("vault is not unlocked") || desc.contains("vault locked") {
            return true
        }
        return false
    }

    static func isAuthError(_ error: Error) -> Bool {
        if let storageError = error as? StorageError {
            if case .authenticationFailed = storageError { return true }
            if case .serverError(let code, _) = storageError { return code == 401 || code == 403 }
        }
        if case WebDAVError.serverError(let code) = error {
            return code == 401 || code == 403
        }
        if let vfsError = error as? VFSError {
            switch vfsError {
            case .invalidPassword, .vaultLocked, .authenticationFailed: return true
            default: return false
            }
        }
        return false
    }

    static func isPermanentError(_ error: Error, retryCount: Int) -> Bool {
        if let storageError = error as? StorageError {
            switch storageError {
            case .indeterminateMutation: return true
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

    public func resolveRelativePath(fileId: String, name: String, parentId: String? = nil, remotePath: String? = nil) -> String {
        // 1. Direct parentId given
        if let parentId = parentId, !parentId.isEmpty, parentId != "ROOT", parentId != "/" {
            if parentId.hasPrefix("/") {
                let cleaned = parentId.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return cleaned.isEmpty ? name : "\(cleaned)/\(name)"
            }
            let vfs = contextLock.withLock { configuredVFS }
            if let resolved = vfs?.resolveRelativePath(name: name, parentId: parentId) {
                return resolved
            }
        }
        
        // 2. Try looking up in metadataStore
        if let meta = metadataStore.getMetadata(fileId: fileId) {
            let metaParent = meta.parentId
            if !metaParent.isEmpty && metaParent != "ROOT" && metaParent != "/" {
                return resolveRelativePath(fileId: fileId, name: meta.name.isEmpty ? name : meta.name, parentId: metaParent, remotePath: remotePath)
            }
        }
        
        // 3. Try remotePath
        if let remotePath = remotePath, !remotePath.isEmpty {
            let cleaned = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        
        return name
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
            let fileName = URL(fileURLWithPath: remotePath).lastPathComponent
            let relativePath = resolveRelativePath(fileId: fileId, name: fileName, remotePath: remotePath)
            let cleartextSize = (try? fileManager.attributesOfItem(atPath: localPath)[.size] as? Int64) ?? 0
            
            FileProgressPublisher.shared.startProgress(
                fileId: fileId,
                fileName: fileName,
                relativePath: relativePath,
                vaultId: vaultId,
                totalBytes: cleartextSize,
                kind: .uploading
            )
            defer {
                FileProgressPublisher.shared.finishProgress(fileId: fileId)
            }
            
            var lastUploadProgress: Double = 0.0
            var lastUploadTime = Date()
            let uploadProgress: (Double) -> Void = { fraction in
                let completed = Int64(fraction * Double(cleartextSize))
                FileProgressPublisher.shared.updateProgress(fileId: fileId, completedBytes: completed)
                let now = Date()
                if fraction >= 1.0 || ((fraction - lastUploadProgress) >= 0.05 && now.timeIntervalSince(lastUploadTime) >= 0.25) {
                    lastUploadProgress = fraction
                    lastUploadTime = now
                    try? self.queue.touchStartedAt(id: item.id)
                    try? self.metadataStore.mutateMetadata(fileId: fileId) { metadata in
                        metadata.uploadProgress = fraction
                        metadata.syncStatus = .uploading
                    }
                }
            }
            if let expectedETag = item.expectedETag {
                result.etag = try await storageClient.uploadFile(localURL: URL(fileURLWithPath: localPath), to: remotePath, expectedETag: expectedETag, progress: uploadProgress)
            } else {
                result.etag = try await storageClient.uploadFile(localURL: URL(fileURLWithPath: localPath), to: remotePath, mode: .createIfAbsent, progress: uploadProgress)
            }
            result.remotePath = remotePath
            result.stagedPath = stagedPath(localPath)
            if getMetadata(fileId: fileId) == nil {
                try metadataStore.updateMetadataPersistent(FileMetadata(
                    fileId: fileId,
                    name: fileName,
                    parentId: (remotePath as NSString).deletingLastPathComponent,
                    isDirectory: false,
                    syncStatus: .uploading,
                    remotePath: remotePath,
                    size: cleartextSize,
                    downloadProgress: 1.0,
                    uploadProgress: 1.0,
                    lastSyncTime: Date()
                ))
            } else {
                try? metadataStore.mutateMetadata(fileId: fileId) { metadata in
                    metadata.uploadProgress = 1.0
                    metadata.syncStatus = .uploading
                }
            }
        case .encryptedUpload(let fileId, let name, let parentId, let localPath, let operationVault):
            guard let vfs, vfs.isEncrypted, vfs.vaultId == operationVault else { throw SyncError.operationFailed("The target encrypted vault is not unlocked") }
            guard fileManager.fileExists(atPath: localPath) else { throw SyncError.operationFailed("Pending upload content is missing") }
            let relativePath = resolveRelativePath(fileId: fileId, name: name, parentId: parentId)
            let cleartextSize = (try? fileManager.attributesOfItem(atPath: localPath)[.size] as? Int64) ?? 0
            
            FileProgressPublisher.shared.startProgress(
                fileId: fileId,
                fileName: name,
                relativePath: relativePath,
                vaultId: operationVault,
                totalBytes: cleartextSize,
                kind: .uploading
            )
            defer {
                FileProgressPublisher.shared.finishProgress(fileId: fileId)
            }
            
            var lastEncUploadProgress: Double = 0.0
            var lastEncUploadTime = Date()
            let uploaded = try await vfs.uploadFile(localURL: URL(fileURLWithPath: localPath), name: name, parentId: parentId, expectedETag: item.expectedETag) { fraction in
                let completed = Int64(fraction * Double(cleartextSize))
                FileProgressPublisher.shared.updateProgress(fileId: fileId, completedBytes: completed)
                let now = Date()
                if fraction >= 1.0 || ((fraction - lastEncUploadProgress) >= 0.05 && now.timeIntervalSince(lastEncUploadTime) >= 0.25) {
                    lastEncUploadProgress = fraction
                    lastEncUploadTime = now
                    try? self.queue.touchStartedAt(id: item.id)
                    try? self.metadataStore.mutateMetadata(fileId: fileId) { metadata in
                        metadata.uploadProgress = fraction
                        metadata.syncStatus = .uploading
                    }
                }
            }
            guard vfs.vaultId == operationVault else { throw SyncError.operationFailed("The vault changed during upload; the original edit is retained") }
            vfs.reconcileOfflineItem(oldId: item.operation.fileId, item: uploaded)
            result.etag = uploaded.etag
            result.remotePath = uploaded.remotePath
            result.replacement = uploaded
            result.stagedPath = stagedPath(localPath)
            try? metadataStore.mutateMetadata(fileId: uploaded.id) { metadata in
                metadata.uploadProgress = 1.0
                metadata.syncStatus = .uploading
            }
        case .download(let fileId, let remotePath, let localPath):
            let url = URL(fileURLWithPath: localPath)
            let fileName = url.lastPathComponent
            let relativePath = resolveRelativePath(fileId: fileId, name: fileName, remotePath: remotePath)
            let totalSize = metadataStore.getMetadata(fileId: fileId)?.size ?? 0
            
            FileProgressPublisher.shared.startProgress(
                fileId: fileId,
                fileName: fileName,
                relativePath: relativePath,
                vaultId: vaultId,
                totalBytes: totalSize,
                kind: .downloading
            )
            defer {
                FileProgressPublisher.shared.finishProgress(fileId: fileId)
            }
            
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var lastDownloadProgress: Double = 0.0
            var lastDownloadTime = Date()
            result.etag = try await storageClient.downloadFile(path: remotePath, to: url, expectedETag: item.expectedETag) { fraction in
                let completed = Int64(fraction * Double(totalSize))
                FileProgressPublisher.shared.updateProgress(fileId: fileId, completedBytes: completed)
                let now = Date()
                if fraction >= 1.0 || ((fraction - lastDownloadProgress) >= 0.05 && now.timeIntervalSince(lastDownloadTime) >= 0.25) {
                    lastDownloadProgress = fraction
                    lastDownloadTime = now
                    try? self.metadataStore.mutateMetadata(fileId: fileId) { metadata in
                        metadata.downloadProgress = fraction
                        metadata.syncStatus = .downloading
                    }
                }
            }
            try metadataStore.mutateMetadata(fileId: fileId) { metadata in
                metadata.localPath = localPath
                metadata.downloadProgress = 1
                metadata.syncStatus = .downloading
            }
            result.remotePath = remotePath
        case .delete(let fileId, let remotePath):
            let metadata = try metadataStore.getMetadataPersistent(fileId: fileId)
            if storageClient.requiresETagForUpdate && metadata == nil {
                throw StorageError.serverError(statusCode: 412, message: "Unknown deletion target cannot be safely classified")
            }
            let isDirectory = metadata?.isDirectory == true
            let revision = isDirectory ? StorageContentVerification.collectionDeletionETag(item.expectedETag) : try StorageContentVerification.mutationETag(item.expectedETag, required: storageClient.requiresETagForUpdate)
            let effectivePath = metadata?.remotePath ?? remotePath
            do {
                if let vfs, vfs.isEncrypted {
                    let deletingVault = vfs.vaultId
                    try await vfs.deleteRemoteItem(remotePath: effectivePath, directoryId: isDirectory ? fileId : nil, expectedETag: revision)
                    guard vfs.vaultId == deletingVault else { throw SyncError.operationFailed("The vault changed during deletion") }
                    vfs.deleteFromLocalDatabaseOnly(itemId: fileId)
                } else {
                    // RFC 4918 collection DELETE lets the server delete the complete
                    // subtree in one request; the client never enumerates children.
                    try await storageClient.delete(path: effectivePath, expectedETag: revision)
                }
            } catch StorageError.notFound { }
            catch {
                if isDirectory && revision == nil && StorageContentVerification.deletionOutcomeIsUncertain(error) {
                    throw StorageError.indeterminateMutation("Directory DELETE must be checked before retrying")
                }
                throw error
            }
            result.deleted = true
        case .deleteItem(let fileId, let remotePath, let isDirectory, let directoryId, let operationVault):
            let revision = isDirectory ? StorageContentVerification.collectionDeletionETag(item.expectedETag) : try StorageContentVerification.mutationETag(item.expectedETag, required: storageClient.requiresETagForUpdate)
            let effectivePath = try metadataStore.getMetadataPersistent(fileId: fileId)?.remotePath ?? remotePath
            do {
                if let vfs, vfs.isEncrypted {
                    guard vfs.vaultId == operationVault else { throw SyncError.operationFailed("The deletion belongs to another vault") }
                    try await vfs.deleteRemoteItem(remotePath: effectivePath, directoryId: isDirectory ? (directoryId ?? fileId) : nil, expectedETag: revision)
                    guard vfs.vaultId == operationVault else { throw SyncError.operationFailed("The vault changed during deletion") }
                    vfs.deleteFromLocalDatabaseOnly(itemId: fileId)
                } else {
                    guard directoryId == nil else { throw SyncError.operationFailed("The encrypted deletion target is unavailable") }
                    if let vfs, vfs.vaultId != operationVault { throw SyncError.operationFailed("The deletion belongs to another vault") }
                    try await storageClient.delete(path: effectivePath, expectedETag: revision)
                }
            } catch StorageError.notFound { }
            catch {
                if isDirectory && revision == nil && StorageContentVerification.deletionOutcomeIsUncertain(error) {
                    throw StorageError.indeterminateMutation("Directory DELETE must be checked before retrying")
                }
                throw error
            }
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
            if storageClient.requiresETagForUpdate && item.expectedETag == nil {
                throw StorageError.serverError(statusCode: 412, message: "Move has no verified remote revision")
            }
            try await storageClient.move(from: source, to: target, expectedETag: item.expectedETag)
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
