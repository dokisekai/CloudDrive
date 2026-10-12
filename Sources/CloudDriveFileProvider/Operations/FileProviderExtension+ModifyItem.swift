import Foundation
import FileProvider
import UniformTypeIdentifiers
import CloudDriveCore
import CloudDriveRecovery

extension FileProviderExtension {
    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        
        logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        logInfo(.fileOps, "📁 Starting modifyItem")
        logInfo(.fileOps, "Item name: \(item.filename)")
        logInfo(.fileOps, "Item ID: \(item.itemIdentifier.rawValue)")
        logInfo(.fileOps, "Changed fields: \(changedFields)")
        logInfo(.fileOps, "Options: \(options)")
        logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        let progress = Progress(totalUnitCount: 100)
        
        let task = Task { [weak self] in
            guard let self = self else {
                logError(.fileOps, "modifyItem failed: self is nil")
                completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
                return
            }
            
            do {
                try Task.checkCancellation()
               try await self.ensureVaultUnlocked()
                let fileId = item.itemIdentifier.rawValue
                
                // 1. Retrieve recorded local info prior to changes (to know source parent and previous name)
                let originalVfsItem = try? self.findItem(identifier: fileId)
                let initialSaveMetadata = try self.syncManager.getMetadataPersistent(fileId: originalVfsItem?.id ?? fileId)
                if let originalVfsItem { try self.validateBaseVersion(version, item: originalVfsItem, preserving: newContents) }
                let oldParentIdentifier: NSFileProviderItemIdentifier?
                if let oldParent = originalVfsItem?.parentId {
                    oldParentIdentifier = (oldParent == "ROOT" || oldParent == "/") ? .rootContainer : NSFileProviderItemIdentifier(oldParent)
                } else {
                    oldParentIdentifier = nil
                }
                
                var currentVfsItem = originalVfsItem
                
                // 2. Check and handle Move/Reparent and Rename
                let isReparenting = changedFields.contains(.parentItemIdentifier) && (oldParentIdentifier != item.parentItemIdentifier)
                let isRenaming = changedFields.contains(.filename) && (originalVfsItem?.name != item.filename)
                
                if isReparenting || isRenaming {
                    // 2.1 Handle moving item to Trash (.trashContainer)
                    if item.parentItemIdentifier == .trashContainer {
                        logInfo(.fileOps, "🗑️ modifyItem: reparenting to .trashContainer -> trashing item: \(fileId)")
                        guard let vfsItem = originalVfsItem ?? (try? self.findItem(identifier: fileId)) else {
                            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
                            return
                        }
                        logInfo(.fileOps, "🔥 modifyItem: Permanently deleting item: \(vfsItem.name) (\(fileId))")
                        if vfsItem.isDirectory { try self.preserveLocalEditBeforeDeletion(vfsItem, fileId: fileId) }
                        let baseline = try self.syncManager.getMetadataPersistent(fileId: fileId)
                        let remotePath = vfsItem.remotePath ?? baseline?.remotePath ?? ""
                        if !remotePath.isEmpty && baseline?.syncStatus != .localOnly {
                            if !vfsItem.isDirectory && (baseline?.syncStatus == .pendingUpload || baseline?.syncStatus == .uploading || self.syncManager.hasPendingUpload(fileId: fileId)) {
                                let source = baseline?.localPath.map { URL(fileURLWithPath: $0) } ?? self.cacheManager.localPath(for: fileId)
                                let backups = DeletedPayloadBackupStore(vaultId: self.currentVaultIdentifier)
                                let backup = try backups.preserve(source: source, fileId: fileId, name: vfsItem.name, parentId: vfsItem.parentId, remotePath: remotePath, expectedETag: baseline?.etag)
                                let preserved = try backups.payload(for: backup.id, verifyIntegrity: false)
                                var tombstone = baseline ?? FileMetadata(fileId: fileId, name: vfsItem.name, parentId: vfsItem.parentId, isDirectory: false, syncStatus: .pendingDelete, remotePath: remotePath)
                                tombstone.localPath = preserved.path
                                tombstone.syncStatus = .pendingDelete
                                try self.syncManager.updateMetadataPersistent(tombstone)
                            }
                            try self.syncManager.enqueuePersistent(.deleteItem(
                                fileId: fileId,
                                remotePath: remotePath,
                                isDirectory: vfsItem.isDirectory,
                                directoryId: vfsItem.isDirectory && self.vfs.isEncrypted ? fileId : nil,
                                vaultId: self.currentVaultIdentifier
                            ))
                        }
                        self.vfs.deleteFromLocalDatabaseOnly(itemId: fileId)
                        if vfsItem.isDirectory {
                            self.cacheManager.removeDirectoryCache(forDirectoryPrefix: fileId)
                        } else {
                            try? self.cacheManager.removeCachedFile(fileId: fileId)
                        }
                        ThumbnailManager.shared.invalidate(fileId: self.thumbnailIdentifier(fileId))
                        if let oldParent = oldParentIdentifier {
                            self.signalEnumeratorDebounced(for: oldParent)
                        }
                        self.signalEnumeratorDebounced(for: .workingSet)
                        
                        let trashedItem = self.makeItem(
                            identifier: item.itemIdentifier,
                            parentIdentifier: .trashContainer,
                            filename: vfsItem.name,
                            contentType: vfsItem.isDirectory ? .folder : .data,
                            capabilities: [.allowsReading, .allowsDeleting, .allowsReparenting],
                            documentSize: vfsItem.size > 0 ? vfsItem.size : nil,
                            contentModificationDate: vfsItem.modifiedAt,
                            creationDate: vfsItem.modifiedAt,
                            isEncrypted: self.vfs.isEncrypted
                        )
                        progress.completedUnitCount = 100
                        completionHandler(trashedItem, [], false, nil)
                        return
                    }
                    
                    let targetParentRaw = item.parentItemIdentifier.rawValue
                    let actualTargetParentId: String
                    if item.parentItemIdentifier == .rootContainer || targetParentRaw == "ROOT" {
                        actualTargetParentId = "ROOT"
                    } else if self.vfs.isEncrypted {
                        actualTargetParentId = targetParentRaw
                    } else {
                        actualTargetParentId = targetParentRaw.hasPrefix("/") ? targetParentRaw : "/\(targetParentRaw)"
                    }
                    
                    let newName = isRenaming ? item.filename : nil
                    let finalTargetName = newName ?? originalVfsItem?.name ?? item.filename
                    if let existingChildren = try? self.vfs.listDirectory(directoryId: actualTargetParentId) {
                        if existingChildren.contains(where: { $0.name.localizedCaseInsensitiveCompare(finalTargetName) == .orderedSame && $0.id != fileId }) {
                            logWarning(.fileOps, "⚠️ FileProvider.modifyItem: Filename collision detected: \(finalTargetName) in parent \(actualTargetParentId)")
                            throw NSFileProviderError(.filenameCollision)
                        }
                    }
                    logInfo(.fileOps, "📁 FileProvider: Executing move/rename - Source ID: \(fileId), Target Parent ID: \(actualTargetParentId), New Name: \(newName ?? "unchanged")")
                    
                    let movedItem = try await self.vfs.moveItem(
                        itemId: fileId,
                        newParentId: actualTargetParentId,
                        newName: newName
                    )
                    currentVfsItem = movedItem
                    logSuccess(.fileOps, "✅ FileProvider: Move/rename succeeded: \(movedItem.name) (New ID: \(movedItem.id))")

                    if isRenaming, let newName = newName {
                        let oldName = originalVfsItem?.name ?? ""
                        if newName.hasSuffix(".nosync") && !oldName.hasSuffix(".nosync") {
                            // Renamed to .nosync: exclude from sync
                            self.syncManager.removePendingUploads(for: fileId)
                            self.syncManager.removePendingUploads(for: movedItem.id)
                            var meta = self.syncManager.getMetadata(fileId: movedItem.id) ?? FileMetadata(
                                fileId: movedItem.id,
                                name: newName,
                                parentId: movedItem.parentId,
                                isDirectory: movedItem.isDirectory,
                                syncStatus: .localOnly,
                                localPath: movedItem.localPath,
                                size: movedItem.size
                            )
                            meta.syncStatus = .localOnly
                            self.syncManager.updateMetadata(meta)
                            let relPath = movedItem.parentId == "ROOT" ? newName : "\(movedItem.parentId)/\(newName)"
                            IgnoreRuleEngine.shared.setUserExcluded(vaultId: self.currentVaultIdentifier, path: relPath, isExcluded: true)
                            logInfo(.sync, "🚫 modifyItem: Renamed to .nosync, set to localOnly: \(newName)")
                        } else if oldName.hasSuffix(".nosync") && !newName.hasSuffix(".nosync") {
                            // Renamed away from .nosync: resume sync
                            let oldRelPath = (originalVfsItem?.parentId ?? "ROOT") == "ROOT" ? oldName : "\(originalVfsItem?.parentId ?? "")/\(oldName)"
                            let newRelPath = movedItem.parentId == "ROOT" ? newName : "\(movedItem.parentId)/\(newName)"
                            IgnoreRuleEngine.shared.setUserExcluded(vaultId: self.currentVaultIdentifier, path: oldRelPath, isExcluded: false)
                            IgnoreRuleEngine.shared.setUserExcluded(vaultId: self.currentVaultIdentifier, path: newRelPath, isExcluded: false)
                            var meta = self.syncManager.getMetadata(fileId: movedItem.id) ?? FileMetadata(
                                fileId: movedItem.id,
                                name: newName,
                                parentId: movedItem.parentId,
                                isDirectory: movedItem.isDirectory,
                                syncStatus: .pendingUpload,
                                localPath: movedItem.localPath,
                                size: movedItem.size
                            )
                            meta.syncStatus = .pendingUpload
                            self.syncManager.updateMetadata(meta)
                            if !movedItem.isDirectory {
                                let cacheURL = self.cacheManager.localPath(for: movedItem.id)
                                if FileManager.default.fileExists(atPath: cacheURL.path) {
                                    let staged = try PendingContentStager(vaultId: self.currentVaultIdentifier).stage(cacheURL, filename: newName)
                                    if self.vfs.isEncrypted {
                                        try self.syncManager.enqueuePersistent(.encryptedUpload(
                                            fileId: movedItem.id,
                                            fileName: newName,
                                            parentId: movedItem.parentId,
                                            localPath: staged.path,
                                            vaultId: self.currentVaultIdentifier
                                        ))
                                    } else {
                                        let remotePath = movedItem.parentId == "ROOT" ? "/\(newName)" : "\(movedItem.parentId)/\(newName)"
                                        try self.syncManager.enqueuePersistent(.upload(
                                            fileId: movedItem.id,
                                            localPath: staged.path,
                                            remotePath: remotePath
                                        ))
                                    }
                                }
                            }
                            self.syncManager.processSyncQueue()
                            logInfo(.sync, "🔄 modifyItem: Renamed from .nosync, queued for sync: \(newName)")
                        }
                    }
                    
                    // Signal enumerators for target directory, source directory, and working set
                    self.signalEnumeratorDebounced(for: item.parentItemIdentifier)
                    if let oldParent = oldParentIdentifier, oldParent != item.parentItemIdentifier {
                        self.signalEnumeratorDebounced(for: oldParent)
                    }
                    self.signalEnumeratorDebounced(for: .workingSet)
                    
                    if let vaultId = self.vaultInfo?.id {
                        self.sync.notifyFileChanged(vaultId: vaultId, fileId: movedItem.id)
                    }
                }
                
                // 3. Check and sync system-level pinned policy changes (handles Finder native "Keep Downloaded" and "Remove Download")
                if #available(macOS 13.0, *) {
                    if let policy = item.contentPolicy {
                        if policy == .downloadEagerlyAndKeepDownloaded {
                            self.cacheManager.pinFile(fileId: fileId)
                        } else {
                            if self.cacheManager.getCacheMetadata(fileId: fileId)?.policy == .pinned {
                                self.cacheManager.unpinFile(fileId: fileId)
                            }
                        }
                    }
                }
                
                // 4. Check and handle content modification and upload
                if let newContents = newContents {
                    logInfo(.fileOps, "📄 FileProvider: Modifying file content (asynchronous queue mode): \(item.filename)")
                    let parentId = item.parentItemIdentifier.rawValue
                    let actualParentId: String
                    if item.parentItemIdentifier == .rootContainer || parentId == "ROOT" {
                        actualParentId = "ROOT"
                    } else if self.vfs.isEncrypted {
                        actualParentId = parentId
                    } else {
                        actualParentId = parentId.hasPrefix("/") ? parentId : "/\(parentId)"
                    }
                    
                    let effectiveFileId = currentVfsItem?.id ?? fileId
                    
                    let savedLocalURL = try PendingContentStager(vaultId: currentVaultIdentifier).stage(newContents, filename: item.filename)
                    let effectivePath = savedLocalURL.path
                    let newSize = (try FileManager.default.attributesOfItem(atPath: effectivePath)[.size] as? NSNumber)?.int64Value ?? 0
                    let existingRemotePath = currentVfsItem?.remotePath ?? effectiveFileId
                    try self.syncManager.withJournalCommit {
                        let baseline = try self.syncManager.getMetadataPersistent(fileId: effectiveFileId)
                        let checkPath = actualParentId == "ROOT" ? item.filename : "\(actualParentId)/\(item.filename)"
                        let isExcluded = item.filename.hasSuffix(".nosync")
                            || baseline?.syncStatus == .localOnly
                            || IgnoreRuleEngine.shared.isUserExcluded(vaultId: self.currentVaultIdentifier, path: item.filename)
                            || IgnoreRuleEngine.shared.isUserExcluded(vaultId: self.currentVaultIdentifier, path: checkPath)
                            || IgnoreRuleEngine.shared.shouldIgnore(path: existingRemotePath, name: item.filename, isDirectory: false, vaultId: self.currentVaultIdentifier)
                        let status: SyncStatus = isExcluded ? .localOnly : .pendingUpload
                        let etag = self.requestedETag(version, fileId: effectiveFileId) ?? baseline?.etag
                        let accepted = FileMetadata(fileId: effectiveFileId, name: item.filename, parentId: actualParentId, isDirectory: false, syncStatus: status, localPath: effectivePath, remotePath: existingRemotePath, size: newSize, localModifiedAt: Date(), remoteModifiedAt: baseline?.remoteModifiedAt, etag: etag, downloadProgress: 1, lastSyncTime: baseline?.lastSyncTime)
                        let operation: SyncOperation?
                        if isExcluded { operation = nil }
                        else if self.vfs.isEncrypted {
                            operation = .encryptedUpload(fileId: effectiveFileId, fileName: item.filename, parentId: actualParentId, localPath: effectivePath, vaultId: self.currentVaultIdentifier)
                        } else {
                            let path = existingRemotePath.hasPrefix("/") ? existingRemotePath : (actualParentId == "ROOT" ? "/\(item.filename)" : "\(actualParentId.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(item.filename)")
                            operation = .upload(fileId: effectiveFileId, localPath: effectivePath, remotePath: path.hasPrefix("/") ? path : "/" + path)
                        }
                        try self.syncManager.acceptSavePersistent(metadata: accepted, operation: operation, expectedETag: etag) {
                            if let original = originalVfsItem, let current = currentVfsItem,
                               original.id != current.id || original.name != current.name || original.parentId != current.parentId {
                                // This request may rename and save together. Its own rename
                                // changes the identity, but never authorizes replacing a
                                // local content generation accepted by another request.
                                let latest = try self.syncManager.getMetadataPersistent(fileId: effectiveFileId)
                                guard latest?.localModifiedAt == initialSaveMetadata?.localModifiedAt,
                                      latest?.size == initialSaveMetadata?.size else {
                                    _ = try DeletedPayloadBackupStore(vaultId: self.currentVaultIdentifier).preserve(source: savedLocalURL, fileId: effectiveFileId, name: item.filename, parentId: actualParentId, remotePath: existingRemotePath, expectedETag: etag)
                                    throw NSFileProviderError(.versionNoLongerAvailable)
                                }
                            } else if let current = currentVfsItem ?? originalVfsItem {
                                try self.validateBaseVersion(version, item: current, preserving: savedLocalURL)
                            }
                        }
                        // Cache and listing publication share the accepted generation's
                        // lock. A late earlier request cannot overwrite a newer cache.
                        do {
                            try self.cacheManager.cacheFile(fileId: effectiveFileId, from: savedLocalURL, policy: .automatic)
                            if var published = try self.syncManager.getMetadataPersistent(fileId: effectiveFileId), published.localPath == effectivePath {
                                published.localPath = self.cacheManager.localPath(for: effectiveFileId).path
                                try self.syncManager.updateMetadataPersistent(published)
                            }
                        } catch {
                            // The accepted immutable stage remains authoritative if cache
                            // publication or its metadata confirmation cannot complete.
                            logWarning(.sync, "Saved edit retained in staging after cache publication failure: \(error.localizedDescription)")
                        }
                        self.vfs.recordOfflineFile(id: effectiveFileId, name: item.filename, parentId: actualParentId, size: newSize, remotePath: existingRemotePath)
                        currentVfsItem = VirtualFileItem(id: effectiveFileId, name: item.filename, isDirectory: false, size: newSize, modifiedAt: accepted.localModifiedAt ?? Date(), parentId: actualParentId, syncStatus: status, localPath: effectivePath, remotePath: existingRemotePath, etag: etag)
                    }
                    ThumbnailManager.shared.invalidate(fileId: self.thumbnailIdentifier(effectiveFileId))
                    self.signalEnumeratorDebounced(for: item.parentItemIdentifier)
                    self.signalEnumeratorDebounced(for: .workingSet)

                }

            // 4. Return latest item metadata to system
            let finalItem: FileProviderItem
            if let vfsItem = currentVfsItem {
                finalItem = self.makeItem(vfsItem: vfsItem, isEncrypted: self.vfs.isEncrypted)
            } else {
                finalItem = self.makeItem(
                    identifier: item.itemIdentifier,
                    parentIdentifier: item.parentItemIdentifier,
                    filename: item.filename,
                    contentType: item.contentType ?? .data,
                    capabilities: [.allowsReading, .allowsWriting, .allowsDeleting, .allowsTrashing, .allowsRenaming, .allowsReparenting, .allowsEvicting],
                    documentSize: item.documentSize as? Int64,
                    contentModificationDate: Date(),
                    creationDate: Date(),
                    isEncrypted: self.vfs.isEncrypted
                )
            }
            
            progress.completedUnitCount = 100
            completionHandler(finalItem, [], false, nil)
            
        } catch is CancellationError {
            completionHandler(nil, [], false, CocoaError(.userCancelled))
        } catch let error as VFSError {
            logError(.fileOps, "❌ FileProvider: VFSError in modifyItem: \(error)")
            let fpError = mapToFileProviderError(error)
            progress.completedUnitCount = 100
            completionHandler(nil, [], false, fpError)
        } catch let error as NSFileProviderError {
            logError(.fileOps, "❌ FileProvider: NSFileProviderError in modifyItem: \(error)")
            progress.completedUnitCount = 100
            completionHandler(nil, [], false, error)
        } catch {
            logError(.fileOps, "❌ FileProvider: Unknown error in modifyItem: \(error)")
            let fpError = mapToFileProviderError(error)
            progress.completedUnitCount = 100
            completionHandler(nil, [], false, fpError)
        }
    }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }
}
