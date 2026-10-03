import Foundation
import FileProvider
import UniformTypeIdentifiers
import CloudDriveCore

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
                        } else if policy == .downloadLazilyAndEvictOnRemoteUpdate {
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
                    
                    // 1. Stage updated content in pending_uploads
                    let savedLocalURL = try PendingContentStager(vaultId: currentVaultIdentifier).stage(newContents, filename: item.filename)
                    let effectivePath = savedLocalURL.path
                    let newSize = (try? FileManager.default.attributesOfItem(atPath: effectivePath)[.size] as? Int64) ?? 0
                    
                    // 2. Cache updated content locally
                    try? self.cacheManager.cacheFile(fileId: effectiveFileId, from: newContents, policy: .automatic)
                    ThumbnailManager.shared.invalidate(fileId: self.thumbnailIdentifier(effectiveFileId))
                    
                    // 3. Update local VFS database record
                    let existingRemotePath = currentVfsItem?.remotePath ?? effectiveFileId
                    self.vfs.recordOfflineFile(
                        id: effectiveFileId,
                        name: item.filename,
                        parentId: actualParentId,
                        size: newSize,
                        remotePath: existingRemotePath
                    )
                    
                    // 4. Preserve the downloaded remote revision for conditional upload.
                    let baseline = self.syncManager.getMetadata(fileId: effectiveFileId)
                    self.syncManager.updateMetadata(FileMetadata(
                        fileId: effectiveFileId,
                        name: item.filename,
                        parentId: actualParentId,
                        isDirectory: false,
                        syncStatus: .pendingUpload,
                        localPath: self.cacheManager.localPath(for: effectiveFileId).path,
                        remotePath: existingRemotePath,
                        size: newSize,
                        localModifiedAt: Date(),
                        remoteModifiedAt: baseline?.remoteModifiedAt,
                        etag: baseline?.etag,
                        downloadProgress: 1.0,
                        lastSyncTime: baseline?.lastSyncTime
                    ))
                    
                    // 5. Update local in-memory representation
                    currentVfsItem = VirtualFileItem(
                        id: effectiveFileId,
                        name: item.filename,
                        isDirectory: false,
                        size: newSize,
                        modifiedAt: Date(),
                        parentId: actualParentId,
                        syncStatus: .pendingUpload,
                        localPath: self.cacheManager.localPath(for: effectiveFileId).path,
                        remotePath: existingRemotePath
                    )
                    
                    // 6. Signal enumerators
                    self.signalEnumeratorDebounced(for: item.parentItemIdentifier)
                    self.signalEnumeratorDebounced(for: .workingSet)
                    
                    // 7. Queue asynchronous background upload
                    if self.vfs.isEncrypted {
                        try self.syncManager.enqueuePersistent(.encryptedUpload(
                            fileId: effectiveFileId,
                            fileName: item.filename,
                            parentId: actualParentId,
                            localPath: effectivePath,
                            vaultId: self.currentVaultIdentifier
                        ))
                    } else {
                        let remotePath: String
                        if !existingRemotePath.isEmpty && existingRemotePath.hasPrefix("/") {
                            remotePath = existingRemotePath
                        } else if actualParentId == "ROOT" {
                            remotePath = "/\(item.filename)"
                        } else if actualParentId.hasSuffix("/") {
                            remotePath = "\(actualParentId)\(item.filename)"
                        } else {
                            remotePath = "\(actualParentId)/\(item.filename)"
                        }
                        try self.syncManager.enqueuePersistent(.upload(
                            fileId: effectiveFileId,
                            localPath: effectivePath,
                            remotePath: remotePath
                        ))
                    }
                    logSuccess(.fileOps, "✅ modifyItem: File content staged locally & queued for async upload: \(item.filename)")
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
                    capabilities: [.allowsReading, .allowsWriting, .allowsDeleting, .allowsRenaming, .allowsReparenting],
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
            let fpError = NSFileProviderError(.cannotSynchronize)
            progress.completedUnitCount = 100
            completionHandler(nil, [], false, fpError)
        }
    }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }
}
