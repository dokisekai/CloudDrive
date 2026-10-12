import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CloudDriveSystem

extension SyncService {
    enum JournalFaultPoint { case enqueuePrepared, enqueueMetadataWritten, completionReceiptWritten, completionMetadataWritten, completionQueueCommitted }

    /// Runs under commit.lock before accepting another intent or contacting storage.
    func recoverJournalCommits() throws {
        for entry in try queue.pendingCommitEntries() {
            switch entry.kind {
            case .enqueue:
                guard let item = entry.item else { throw SyncError.operationFailed("Invalid prepared enqueue journal") }
                // Final queue insertion and removal of this intent share one SQLite
                // transaction. A remaining intent was never accepted by the queue.
                try metadataStore.restorePreparedMetadata(fileId: item.operation.fileId, previous: entry.metadataBefore, prepared: entry.metadataPrepared)
                try queue.conn.withTransaction { try queue.removeCommitEntry(id: entry.id) }
            case .completion:
                guard let receipt = entry.receipt else { throw SyncError.operationFailed("Invalid completion journal") }
                _ = try finalizeCompletion(receipt, entryId: entry.id, injectFaults: false)
            }
        }
    }

    func commitCompletedOperation(_ item: SyncQueueItem, result: QueueResult, metadataFallback: FileMetadata? = nil) throws -> String {
        let replacement = result.replacement.map { replacement in
            FileMetadata(fileId: replacement.id, name: replacement.name, parentId: replacement.parentId, isDirectory: replacement.isDirectory, syncStatus: replacement.syncStatus, localPath: replacement.localPath, remotePath: replacement.remotePath, size: replacement.size, localModifiedAt: replacement.modifiedAt, etag: replacement.etag)
        }
        let receipt = SyncCompletionReceipt(item: item, etag: result.etag, remotePath: result.remotePath, replacement: replacement, stagedPath: result.stagedPath, deleted: result.deleted, metadataFallback: metadataFallback)
        let entryId = "completion:" + item.id
        try queue.persistCommitEntry(SyncCommitEntry(id: entryId, kind: .completion, receipt: receipt))
        try journalFaultInjector?(.completionReceiptWritten)
        return try finalizeCompletion(receipt, entryId: entryId, injectFaults: true)
    }

    private func finalizeCompletion(_ receipt: SyncCompletionReceipt, entryId: String, injectFaults: Bool) throws -> String {
        let item = receipt.item
        var effectiveId = receipt.replacement?.fileId ?? item.operation.fileId
        var replacement = receipt.replacement.map(Self.virtualItem)
        var remotePath = receipt.remotePath
        // A rename accepted while PUT was in flight remains a successor.
        if replacement == nil, let uploadedPath = remotePath,
           let successor = try queue.findMoveSuccessor(sourcePath: uploadedPath, excludeId: item.id),
           let moved = try metadataStore.getMetadataPersistent(fileId: successor.movedId) {
            effectiveId = successor.movedId
            replacement = VirtualFileItem(id: successor.movedId, name: moved.name, isDirectory: moved.isDirectory, size: moved.size, modifiedAt: moved.localModifiedAt ?? Date(), parentId: moved.parentId, syncStatus: .pendingMove, remotePath: successor.targetPath, etag: receipt.etag)
            remotePath = successor.targetPath
            try metadataStore.removeMetadataPersistent(fileId: item.operation.fileId)
        }
        if replacement != nil, effectiveId != item.operation.fileId {
            try metadataStore.removeMetadataPersistent(fileId: item.operation.fileId)
        }
        let successorStatus = try queue.successorStatus(fileIds: [item.operation.fileId, effectiveId], excludeId: item.id)
        if receipt.deleted {
            if case .deleteItem(_, _, let isDirectory, _, _) = item.operation, isDirectory {
                try metadataStore.removeDirectoryMetadataPersistent(forDirectoryPrefix: item.operation.fileId)
            } else {
                try metadataStore.removeMetadataPersistent(fileId: item.operation.fileId)
            }
        } else {
            if try metadataStore.getMetadataPersistent(fileId: effectiveId) == nil {
                var restored = receipt.replacement ?? receipt.metadataFallback ?? Self.fallbackMetadata(for: item.operation, remotePath: remotePath)
                if restored.fileId != effectiveId {
                    restored = FileMetadata(fileId: effectiveId, name: replacement?.name ?? restored.name, parentId: replacement?.parentId ?? restored.parentId, isDirectory: replacement?.isDirectory ?? restored.isDirectory, syncStatus: .pendingUpload, localPath: replacement?.localPath, remotePath: remotePath, size: restored.size, localModifiedAt: restored.localModifiedAt, etag: receipt.etag)
                }
                try metadataStore.updateMetadataPersistent(restored)
            }
            try metadataStore.mutateMetadata(fileId: effectiveId) { metadata in
                let localAvailable = metadata.isDirectory || metadata.localPath.map { fileManager.fileExists(atPath: $0) } == true
                let confirmedTag = receipt.etag ?? metadata.etag
                // A listing may observe a later remote edit while the confirmed
                // PUT/GET waits for its local commit. Do not erase that observation.
                let observedLaterRevision = !metadata.isDirectory && metadata.remoteETag.map {
                    $0 != confirmedTag && $0 != receipt.item.expectedETag
                } == true
                let currentLocalAvailable = localAvailable && !observedLaterRevision
                metadata.syncStatus = successorStatus ?? (currentLocalAvailable ? .synced : .cloudOnly)
                if successorStatus == nil {
                    metadata.uploadProgress = 1
                    metadata.downloadProgress = currentLocalAvailable ? 1 : 0
                }
                if let path = remotePath { metadata.remotePath = path }
                if let etag = receipt.etag {
                    metadata.etag = etag
                    if !observedLaterRevision { metadata.remoteETag = etag }
                }
                metadata.lastSyncTime = Date()
            }
        }
        if injectFaults { try journalFaultInjector?(.completionMetadataWritten) }
        try queue.conn.withTransaction {
            _ = try queue.completeItem(id: item.id, fileId: item.operation.fileId, etag: receipt.etag, replacement: replacement)
            try queue.removeCommitEntry(id: entryId)
        }
        if injectFaults { try journalFaultInjector?(.completionQueueCommitted) }
        // Orphaned staged files after a crash are safe; deletion only follows both
        // durable commits, and never precedes acceptance of the remote receipt.
        if let path = receipt.stagedPath {
            var possibleReferences: Set<String> = [path]
            switch receipt.item.operation {
            case .upload(_, let originalPath, _), .encryptedUpload(_, _, _, let originalPath, _): possibleReferences.insert(originalPath)
            default: break
            }
            // A cache publication failure can leave this immutable payload as the
            // latest clean local replica. Keep it until metadata points elsewhere;
            // an unavailable metadata DB must never authorize removing the bytes.
            let isReferenced = (try? metadataStore.referencesLocalPathsPersistent(possibleReferences)) ?? true
            if !isReferenced { try? fileManager.removeItem(atPath: path) }
        }
        if notifiesFileProvider, let targetVault = vaultId ?? activeVFS?.vaultId {
            FileProviderSync.shared.notifyFileChanged(vaultId: targetVault, fileId: effectiveId)
            if effectiveId != item.operation.fileId {
                FileProviderSync.shared.notifyFileChanged(vaultId: targetVault, fileId: item.operation.fileId)
            }
        }
        return effectiveId
    }

    private static func fallbackMetadata(for operation: SyncOperation, remotePath: String?) -> FileMetadata {
        let path = remotePath ?? operation.remotePath ?? operation.fileId
        switch operation {
        case .createDirectory(let id, let name, let parent, _), .encryptedCreateDirectory(let id, let name, let parent, _, _):
            return FileMetadata(fileId: id, name: name, parentId: parent, isDirectory: true, syncStatus: .pendingUpload, remotePath: path)
        case .encryptedUpload(let id, let name, let parent, _, _):
            return FileMetadata(fileId: id, name: name, parentId: parent, isDirectory: false, syncStatus: .pendingUpload, remotePath: path)
        default:
            return FileMetadata(fileId: operation.fileId, name: (path as NSString).lastPathComponent, parentId: (path as NSString).deletingLastPathComponent, isDirectory: false, syncStatus: .pendingUpload, remotePath: path)
        }
    }

    private static func virtualItem(_ metadata: FileMetadata) -> VirtualFileItem {
        VirtualFileItem(id: metadata.fileId, name: metadata.name, isDirectory: metadata.isDirectory, size: metadata.size, modifiedAt: metadata.localModifiedAt ?? Date(), parentId: metadata.parentId, syncStatus: metadata.syncStatus, localPath: metadata.localPath, remotePath: metadata.remotePath, etag: metadata.etag)
    }
}
