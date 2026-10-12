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
import CloudDriveSupport

extension SyncService {
    // MARK: - 队列管理转发
    
    public func addToSyncQueue(_ operation: SyncOperation) {
        do { try enqueuePersistent(operation) }
        catch { Logger.shared.error(.sync, "Cannot accept sync operation: \(error.localizedDescription)") }
    }
    
    public func enqueuePersistent(_ operation: SyncOperation, startProcessing: Bool = true, expectedETag: String? = nil) throws {
        try validate(operation)
        try withJournalCommit { try prepareEnqueueLocked(operation, suppliedMetadata: nil, expectedETag: expectedETag) }
        if startProcessing { processSyncQueue() }
    }

    /// Revalidate the caller's generation and accept its metadata/payload under
    /// the same cross-process commit lease. The validation closure is synchronous.
    public func acceptSavePersistent(metadata: FileMetadata, operation: SyncOperation?, expectedETag: String? = nil, validation: () throws -> Void) throws {
        if let operation {
            try validate(operation)
            guard operation.fileId == metadata.fileId else { throw SyncError.operationFailed("Save metadata and operation identities differ") }
        }
        try withJournalCommit {
            try validation()
            if let operation {
                try prepareEnqueueLocked(operation, suppliedMetadata: metadata, expectedETag: expectedETag)
            } else {
                try metadataStore.updateMetadataPersistent(metadata)
            }
        }
        if operation != nil { processSyncQueue() }
    }

    private func prepareEnqueueLocked(_ operation: SyncOperation, suppliedMetadata: FileMetadata?, expectedETag: String?) throws {
        let previous = try metadataStore.getMetadataPersistent(fileId: operation.fileId)
        let baseline = suppliedMetadata ?? previous
        let implicitTag: String?
        switch operation {
        case .upload, .encryptedUpload: implicitTag = baseline?.etag
        default: implicitTag = baseline?.remoteETag ?? baseline?.etag
        }
        let conditionalTag = expectedETag ?? implicitTag
        let item = SyncQueueItem(operation: operation, expectedETag: conditionalTag, vaultId: self.vaultId)
        let entryId = "enqueue:" + item.id
        var prepared = suppliedMetadata ?? previous
        switch operation {
        case .delete, .deleteItem: prepared?.syncStatus = .pendingDelete
        case .move: prepared?.syncStatus = .pendingMove
        case .download: prepared?.syncStatus = .downloading
        default: prepared?.syncStatus = .pendingUpload
        }
        try queue.persistCommitEntry(SyncCommitEntry(id: entryId, kind: .enqueue, item: item, metadataBefore: previous, metadataPrepared: prepared))
        do {
            try journalFaultInjector?(.enqueuePrepared)
            if let prepared { try metadataStore.updateMetadataPersistent(prepared) }
            try journalFaultInjector?(.enqueueMetadataWritten)
            try queue.finalizeEnqueue(item, entryId: entryId)
        } catch {
            // Fault injection models abrupt process death. Real write failures
            // attempt immediate CAS rollback; the intent remains if that fails.
            if journalFaultInjector == nil { try? recoverJournalCommits() }
            throw error
        }
    }

    func withJournalCommit<Result>(_ action: () throws -> Result) throws -> Result {
        let url = queue.persistenceURL.appendingPathExtension("commit.lock").standardizedFileURL.resolvingSymlinksInPath()
        let scopeKey = "CloudDrive.sync.commit." + url.path
        let scopes = Thread.current.threadDictionary
        if scopes[scopeKey] != nil { return try action() }
        guard let lease = try SyncFileLease(url: url, nonBlocking: false) else {
            throw SyncError.operationFailed("Cannot acquire sync commit lease")
        }
        scopes[scopeKey] = true
        defer {
            scopes.removeObject(forKey: scopeKey)
            lease.release()
        }
        try recoverJournalCommits()
        return try action()
    }

    func validate(_ operation: SyncOperation) throws {
        let operationVault = operation.vaultId
        if let vaultId, let operationVault, operationVault != vaultId {
            throw SyncError.operationFailed("Operation belongs to a different vault: \(operationVault) vs \(vaultId)")
        }
    }

    func validate(_ item: SyncQueueItem) throws {
        try validate(item.operation)
        let itemVault = item.vaultId ?? item.operation.vaultId
        if let vaultId, let itemVault, itemVault != vaultId {
            throw SyncError.operationFailed("Item belongs to a different vault: \(itemVault) vs \(vaultId)")
        }
    }

    public func updatePendingOperation(oldFileId: String, newFileId: String, newRemotePath: String, newName: String, newParentId: String, sourceRemotePath: String? = nil) {
        queue.updatePendingOperation(oldFileId: oldFileId, newFileId: newFileId, newRemotePath: newRemotePath, newName: newName, newParentId: newParentId, sourceRemotePath: sourceRemotePath)
    }
    
    public func hasPendingUpload(fileId: String) -> Bool {
        queue.hasPendingUpload(fileId: fileId)
    }

    public func removePendingUploads(for fileId: String) {
        queue.removePendingUploads(for: fileId)
    }

    public func hasPendingOperation(fileId: String) -> Bool {
        queue.hasPendingOperation(fileId: fileId)
    }
    
    public func getSyncQueueCount() -> Int {
        queue.getCount()
    }
    

}
