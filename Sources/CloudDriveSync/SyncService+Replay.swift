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
import CloudDriveSystem

extension SyncService {
    func processQueueAsync() async -> Date? {
        let lease: SyncFileLease
        do {
            guard let acquired = try queue.acquireConsumerLease() else {
                return Date().addingTimeInterval(2)
            }
            lease = acquired
        } catch {
            Logger.shared.error(.sync, "Cannot acquire queue lease: \(error.localizedDescription)")
            return Date().addingTimeInterval(10)
        }
        defer { lease.release() }
        let sleepAssertion = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "CloudDrive WebDAV Sync in Progress"
        )
        defer { ProcessInfo.processInfo.endActivity(sleepAssertion) }
        // The OS lease proves no previous consumer remains alive.
        // Recover even tasks interrupted less than a minute before restart.
        do {
            try withJournalCommit {}
            try queue.resetAbandonedItems(olderThan: 0)
        }
        catch { return Date().addingTimeInterval(10) }

        while !Task.isCancelled {
            let item: SyncQueueItem
            do {
                guard let selected = try queue.nextReadyItem() else {
                    return try queue.nextRetryDate()
                }
                guard let claimed = try queue.claimItem(id: selected.id) else { continue }
                item = claimed
            } catch {
                Logger.shared.error(.sync, "Cannot read sync journal: \(error.localizedDescription)")
                return Date().addingTimeInterval(10)
            }
            do {
                let metadataBeforeExecution = try metadataStore.getMetadataPersistent(fileId: item.operation.fileId)
                let result = try await processQueueItem(item)
                _ = try withJournalCommit { try commitCompletedOperation(item, result: result, metadataFallback: metadataBeforeExecution) }
            } catch {
                // A durable remote receipt must be replayed locally, never retried
                // as another conditional network mutation.
                do {
                    if try queue.hasCommitEntry(id: "completion:" + item.id) {
                        Logger.shared.error(.sync, "Remote operation confirmed; local commit recovery pending: \(error.localizedDescription)")
                        return Date().addingTimeInterval(10)
                    }
                } catch { return Date().addingTimeInterval(10) }
                let conflict = Self.isConflict(error)
                let isLock = Self.isLockError(error)
                let isAuth = Self.isAuthError(error) || isLock
                let isPermanent = !isLock && Self.isPermanentError(error, retryCount: item.retryCount)
                let retryAt: Date?
                if conflict || isAuth || isPermanent {
                    retryAt = nil
                } else {
                    retryAt = Date().addingTimeInterval(min(300, pow(2, Double(min(item.retryCount + 1, 8)))))
                }
                do {
                    try queue.recordFailure(
                        id: item.id,
                        message: error.localizedDescription,
                        conflict: conflict,
                        nextAttemptAt: retryAt,
                        isAuthFailure: isAuth,
                        isPermanentFailure: isPermanent
                    )
                    try metadataStore.mutateMetadata(fileId: item.operation.fileId) { metadata in
                        metadata.syncStatus = conflict ? .conflict : ((isPermanent || (isAuth && !isLock)) ? .error : Self.pendingStatus(for: item.operation))
                    }
                } catch {
                    Logger.shared.error(.sync, "Cannot persist failed sync state: \(error.localizedDescription)")
                }
                if notifiesFileProvider, let targetVault = vaultId ?? activeVFS?.vaultId {
                    FileProviderSync.shared.notifyFileChanged(vaultId: targetVault, fileId: item.operation.fileId)
                }
                if isLock {
                    Logger.shared.warning(.sync, "Sync suspended because vault is locked: \(item.operation.fileId)")
                    return nil
                }
                // Never execute a dependent successor after its predecessor failed.
                Logger.shared.warning(.sync, "Sync suspended with original payload retained: \(item.operation.fileId)")
                continue
            }
        }
        return nil
    }

    static func pendingStatus(for operation: SyncOperation) -> SyncStatus {
        switch operation {
        case .move: return .pendingMove
        case .delete, .deleteItem: return .pendingDelete
        case .download: return .cloudOnly
        default: return .pendingUpload
        }
    }


}
