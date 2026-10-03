import Foundation
import FileProvider
import UniformTypeIdentifiers
import CloudDriveCore
import CloudDriveRecovery

extension FileProviderExtension {
    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let task = Task { [weak self] in
            guard let self else { completionHandler(NSFileProviderError(.noSuchItem)); return }
            do {
                try Task.checkCancellation()
                if identifier == .trashContainer {
                    progress.completedUnitCount = 1
                    completionHandler(nil)
                    return
                }
                try await ensureVaultUnlocked()
                let id = identifier.rawValue
                guard let item = try? findItem(identifier: id) else { completionHandler(nil); return }
                if !item.isDirectory {
                    try? validateBaseVersion(version, item: item)
                }
                
                // Recycle Bin (Soft Delete) Check
                let isRecycleBinFolder = self.vfs.isRecycleBinDirectory(id: item.id)
                let isAlreadyInBin = self.vfs.isItemInRecycleBin(item: item)
                let isBinEnabled = RecycleBinConfig.isEnabled(for: self.currentVaultIdentifier)
                
                if isRecycleBinFolder {
                    logInfo(.fileOps, "🧹 deleteItem: Trashing the Recycle Bin folder itself -> emptying trash")
                    try await self.vfs.emptyTrash()
                    self.signalEnumeratorDebounced(for: .rootContainer)
                    if let bin = self.vfs.getRecycleBinDirectory() {
                        self.signalEnumeratorDebounced(for: NSFileProviderItemIdentifier(bin.id))
                    }
                    self.signalEnumeratorDebounced(for: .workingSet)
                    progress.completedUnitCount = 1
                    completionHandler(nil)
                    return
                }
                
                if isBinEnabled && !isAlreadyInBin {
                    logInfo(.fileOps, "🗑️ deleteItem: Soft-deleting item to RecycleBin folder: \(item.name) (\(id))")
                    _ = try await self.vfs.moveToRecycleBin(item: item)
                    
                    let oldParentIdentifier: NSFileProviderItemIdentifier = (item.parentId == "ROOT" || item.parentId == "/") ? .rootContainer : NSFileProviderItemIdentifier(item.parentId)
                    self.signalEnumeratorDebounced(for: oldParentIdentifier)
                    if let bin = self.vfs.getRecycleBinDirectory() {
                        self.signalEnumeratorDebounced(for: NSFileProviderItemIdentifier(bin.id))
                    }
                    self.signalEnumeratorDebounced(for: .workingSet)
                    progress.completedUnitCount = 1
                    completionHandler(nil)
                    return
                }
                
                logInfo(.fileOps, "🔥 deleteItem: Permanently deleting item: \(item.name) (\(id)) (isInRecycleBin=\(isAlreadyInBin), isBinEnabled=\(isBinEnabled))")
                
                let baseline = syncManager.getMetadata(fileId: id)
                let remotePath = item.remotePath ?? baseline?.remotePath ?? ""

                // 2.3.2 Non-destructive safety snapshot for dirty / unuploaded files before deletion
                let isDirty = baseline?.syncStatus == .pendingUpload || baseline?.syncStatus == .uploading || syncManager.hasPendingUpload(fileId: id)
                if isDirty && !item.isDirectory {
                    let backupDir = CloudDrivePaths.vaultDirectory(for: self.currentVaultIdentifier).appendingPathComponent("DeletedPayloads")
                    try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
                    let tombstoneURL = backupDir.appendingPathComponent("\(UUID().uuidString)_\(item.name)")
                    let cachedURL = cacheManager.localPath(for: id)
                    if FileManager.default.fileExists(atPath: cachedURL.path) {
                        if copyfile(cachedURL.path, tombstoneURL.path, nil, copyfile_flags_t(COPYFILE_CLONE)) != 0 {
                            try? FileManager.default.copyItem(at: cachedURL, to: tombstoneURL)
                        }
                    }
                    // Cancel redundant pending uploads from queue to save bandwidth
                    syncManager.removePendingUploads(for: id)
                }

                if !remotePath.isEmpty {
                    // Keep the path, encrypted directory UUID and tombstone before removing the DB row.
                    var tombstone = baseline ?? FileMetadata(fileId: id, name: item.name, parentId: item.parentId, isDirectory: item.isDirectory, syncStatus: .pendingDelete, remotePath: remotePath, size: item.size)
                    tombstone.syncStatus = .pendingDelete
                    syncManager.updateMetadata(tombstone)
                    try? syncManager.enqueuePersistent(.deleteItem(fileId: id, remotePath: remotePath, isDirectory: item.isDirectory, directoryId: item.isDirectory && vfs.isEncrypted ? id : nil, vaultId: self.currentVaultIdentifier))
                }
                vfs.deleteFromLocalDatabaseOnly(itemId: id)
                if item.isDirectory { cacheManager.removeDirectoryCache(forDirectoryPrefix: id) }
                else { try? cacheManager.removeCachedFile(fileId: id) }
                ThumbnailManager.shared.invalidate(fileId: thumbnailIdentifier(id))
                try? RecycleBinStore.shared.deleteByFileId(fileId: id)
                signalEnumeratorDebounced(for: item.parentId == "ROOT" ? .rootContainer : NSFileProviderItemIdentifier(item.parentId))
                signalEnumeratorDebounced(for: .workingSet)
                progress.completedUnitCount = 1
                completionHandler(nil)
            } catch {
                completionHandler(error is CancellationError ? CocoaError(.userCancelled) : (error as? NSFileProviderError ?? NSFileProviderError(.cannotSynchronize)))
            }
        }
        progress.cancellationHandler = { task.cancel() }
    return progress
    }
}
