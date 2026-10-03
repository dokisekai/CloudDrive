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
    
    public func enqueuePersistent(_ operation: SyncOperation, startProcessing: Bool = true) throws {
        try validate(operation)
        try withJournalCommit {
            _ = try queue.enqueuePersistent(operation, expectedETag: getMetadata(fileId: operation.fileId)?.etag, vaultId: self.vaultId)
            try metadataStore.mutateMetadata(fileId: operation.fileId) { metadata in
                switch operation {
                case .delete, .deleteItem: metadata.syncStatus = .pendingDelete
                case .move: metadata.syncStatus = .pendingMove
                case .download: metadata.syncStatus = .downloading
                default: metadata.syncStatus = .pendingUpload
                }
            }
        }
        if startProcessing { processSyncQueue() }
    }

    func withJournalCommit<Result>(_ action: () throws -> Result) throws -> Result {
        let url = queue.persistenceURL.appendingPathExtension("commit.lock")
        let lease = try SyncFileLease(url: url, nonBlocking: false)
        defer { lease?.release() }
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
