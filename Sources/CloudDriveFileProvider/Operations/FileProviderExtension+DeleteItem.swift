import Foundation
import FileProvider
import UniformTypeIdentifiers
import CloudDriveCore
import CloudDriveRecovery
import CloudDriveSupport

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
                let item = try findItem(identifier: id)
                if !item.isDirectory {
                    try validateBaseVersion(version, item: item)
                }
                
                // Guard against accidental destruction of Cryptomator vault critical files
                let protectedNames: Set<String> = ["masterkey.cryptomator", "masterkey.bkup", "vault.cryptomator", "dirid.c9r"]
                if protectedNames.contains(item.name.lowercased()) {
                    logError(.system, "🛡️ Blocked deletion of protected Cryptomator vault file: \(item.name)")
                    throw NSFileProviderError(.deletionRejected)
                }
                
                logInfo(.fileOps, "🔥 deleteItem: Deleting item: \(item.name) (\(id))")
                
                if item.isDirectory { try preserveLocalEditBeforeDeletion(item, fileId: id) }
                let baseline = try syncManager.getMetadataPersistent(fileId: id)
                let remotePath = item.remotePath ?? baseline?.remotePath ?? ""

                let originalUploads = try syncManager.queue.itemsForFilePersistent(fileId: id).filter {
                    guard $0.operation.fileId == id else { return false }
                    switch $0.operation { case .upload, .encryptedUpload: return true; default: return false }
                }
                let isDirty = baseline?.syncStatus == .pendingUpload || baseline?.syncStatus == .uploading || !originalUploads.isEmpty
                var retainedPayload: URL?
                if isDirty && !item.isDirectory {
                    let source = baseline?.localPath.map { URL(fileURLWithPath: $0) } ?? cacheManager.localPath(for: id)
                    guard FileManager.default.fileExists(atPath: source.path) else {
                        throw SyncError.operationFailed("Cannot preserve the pending edit before deleting")
                    }
                    // Preserve cleartext edits for both encrypted and ordinary vaults.
                    // This independent durable copy is retained after the delete completes.
                    let backups = DeletedPayloadBackupStore(vaultId: self.currentVaultIdentifier)
                    let backup = try backups.preserve(source: source, fileId: id, name: item.name, parentId: item.parentId, remotePath: remotePath, expectedETag: baseline?.etag)
                    retainedPayload = try backups.payload(for: backup.id, verifyIntegrity: false)
                }

                if !remotePath.isEmpty && baseline?.syncStatus != .localOnly {
                    // Keep the path, encrypted directory UUID and tombstone before removing the DB row.
                    var tombstone = baseline ?? FileMetadata(fileId: id, name: item.name, parentId: item.parentId, isDirectory: item.isDirectory, syncStatus: .pendingDelete, remotePath: remotePath, size: item.size)
                    tombstone.syncStatus = .pendingDelete
                    if let retainedPayload { tombstone.localPath = retainedPayload.path }
                    try syncManager.updateMetadataPersistent(tombstone)
                    try syncManager.enqueuePersistent(.deleteItem(fileId: id, remotePath: remotePath, isDirectory: item.isDirectory, directoryId: item.isDirectory && vfs.isEncrypted ? id : nil, vaultId: self.currentVaultIdentifier))
                    // Active transfers retain their original payload until completion.
                    try syncManager.queue.removeUnstartedItemsPersistent(ids: originalUploads.map(\.id))
                }
                vfs.deleteFromLocalDatabaseOnly(itemId: id)
                ItemAliasStore.shared.removeAlias(for: id)
                if item.id != id { ItemAliasStore.shared.removeAlias(for: item.id) }
                if item.isDirectory { cacheManager.removeDirectoryCache(forDirectoryPrefix: id) }
                else { try? cacheManager.removeCachedFile(fileId: id) }
                ThumbnailManager.shared.invalidate(fileId: thumbnailIdentifier(id))
                signalEnumeratorDebounced(for: item.parentId == "ROOT" ? .rootContainer : NSFileProviderItemIdentifier(item.parentId))
                signalEnumeratorDebounced(for: .workingSet)
                progress.completedUnitCount = 1
                completionHandler(nil)
            } catch {
                completionHandler(error is CancellationError ? CocoaError(.userCancelled) : (error as? NSFileProviderError ?? mapToFileProviderError(error)))
            }
        }
        progress.cancellationHandler = { task.cancel() }
    return progress
    }
}
