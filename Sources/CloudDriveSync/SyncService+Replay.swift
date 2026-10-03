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
        try? queue.resetAbandonedItems(olderThan: 60.0)

        while !Task.isCancelled {
            let item: SyncQueueItem
            do {
                let queued = try queue.allItemsPersistent()
                guard !queued.isEmpty else { return nil }
                
                var blockedFileIds = Set<String>()
                var candidate: SyncQueueItem? = nil
                var earliestNextAttempt: Date? = nil
                
                for qItem in queued {
                    let fileId = qItem.operation.fileId
                    if blockedFileIds.contains(fileId) {
                        continue
                    }
                    if qItem.blockedByConflict == true || qItem.isPermanentFailure == true || qItem.isAuthFailure == true {
                        blockedFileIds.insert(fileId)
                        continue
                    }
                    if let next = qItem.nextAttemptAt, next > Date() {
                        blockedFileIds.insert(fileId)
                        if earliestNextAttempt == nil || next < earliestNextAttempt! {
                            earliestNextAttempt = next
                        }
                        continue
                    }
                    if let started = qItem.startedAt {
                        if Date().timeIntervalSince(started) > 120.0 {
                            try? queue.resetStartedAt(id: qItem.id)
                            candidate = qItem
                            break
                        } else {
                            blockedFileIds.insert(fileId)
                            continue
                        }
                    }
                    candidate = qItem
                    break
                }
                
                guard let selected = candidate else {
                    return earliestNextAttempt
                }
                guard let claimed = try queue.claimItem(id: selected.id) else { continue }
                item = claimed
            } catch {
                Logger.shared.error(.sync, "Cannot read sync journal: \(error.localizedDescription)")
                return Date().addingTimeInterval(10)
            }
            do {
                var result = try await processQueueItem(item)
                var effectiveId = result.replacement?.id ?? item.operation.fileId
                try withJournalCommit {
                    // A rename accepted during this upload is a successor, not a
                    // reason to resurrect the old item identity after completion.
                    if result.replacement == nil, let uploadedPath = result.remotePath {
                        if let succ = queue.findMoveSuccessor(sourcePath: uploadedPath, excludeId: item.id),
                           let moved = metadataStore.getMetadata(fileId: succ.movedId) {
                            effectiveId = succ.movedId
                            result.replacement = VirtualFileItem(id: succ.movedId, name: moved.name, isDirectory: moved.isDirectory, size: moved.size, modifiedAt: moved.localModifiedAt ?? Date(), parentId: moved.parentId, syncStatus: .pendingMove, remotePath: succ.targetPath, etag: result.etag)
                            result.remotePath = succ.targetPath
                            try metadataStore.removeMetadataPersistent(fileId: item.operation.fileId)
                        }
                    }
                    let successors = queue.itemsForFiles(fileIds: [item.operation.fileId, effectiveId], excludeId: item.id)
                    if !result.deleted {
                        try metadataStore.mutateMetadata(fileId: effectiveId) { metadata in
                            metadata.syncStatus = successors.isEmpty ? .synced : (successors.contains { if case .move = $0.operation { return true }; return false } ? .pendingMove : .pendingUpload)
                            if let path = result.remotePath { metadata.remotePath = path }
                            if let etag = result.etag { metadata.etag = etag }
                            metadata.lastSyncTime = Date()
                        }
                    }
                    // The accepted payload remains recoverable until metadata is committed.
                    try queue.completeItem(id: item.id, fileId: item.operation.fileId, etag: result.etag, replacement: result.replacement)
                }
                if let localPath = result.stagedPath {
                    try? fileManager.removeItem(atPath: localPath)
                }
                if notifiesFileProvider, let targetVault = vaultId ?? activeVFS?.vaultId {
                    FileProviderSync.shared.notifyFileChanged(vaultId: targetVault, fileId: effectiveId)
                }
            } catch {
                let conflict = Self.isConflict(error)
                let isAuth = Self.isAuthError(error)
                let isPermanent = Self.isPermanentError(error, retryCount: item.retryCount)
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
                        metadata.syncStatus = conflict ? .conflict : .error
                    }
                } catch {
                    Logger.shared.error(.sync, "Cannot persist failed sync state: \(error.localizedDescription)")
                }
                if notifiesFileProvider, let targetVault = vaultId ?? activeVFS?.vaultId {
                    FileProviderSync.shared.notifyFileChanged(vaultId: targetVault, fileId: item.operation.fileId)
                }
                // Never execute a dependent successor after its predecessor failed.
                Logger.shared.warning(.sync, "Sync suspended with original payload retained: \(item.operation.fileId)")
                continue
            }
        }
        return nil
    }


}
