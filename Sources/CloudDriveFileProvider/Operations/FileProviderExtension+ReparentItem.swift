import Foundation
import FileProvider
import UniformTypeIdentifiers
import CloudDriveCore
import CloudDriveRecovery

extension FileProviderExtension {
    func reparentItem(identifier: NSFileProviderItemIdentifier,
                      toParentItemIdentifier parentItemIdentifier: NSFileProviderItemIdentifier,
                      newName: String?,
                      baseVersion version: NSFileProviderItemVersion,
                      request: NSFileProviderRequest,
                      completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
       
       logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
       logInfo(.fileOps, "📁 Starting reparentItem")
       logInfo(.fileOps, "Item ID: \(identifier.rawValue)")
       logInfo(.fileOps, "Target parent ID: \(parentItemIdentifier.rawValue)")
       logInfo(.fileOps, "New name: \(newName ?? "unchanged")")
       logInfo(.fileOps, "Base version: \(version)")
       logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
       
       let progress = Progress(totalUnitCount: 100)
       
       let task = Task { [weak self] in
           guard let self = self else {
               logError(.fileOps, "reparentItem failed: self is nil")
               completionHandler(nil, NSFileProviderError(.noSuchItem))
               return
           }
           
           do {
               try Task.checkCancellation()
               try await self.ensureVaultUnlocked()
               let fileId = identifier.rawValue
               let originalVfsItem = try? self.findItem(identifier: fileId)
               let oldParentIdentifier: NSFileProviderItemIdentifier?
               if let oldParent = originalVfsItem?.parentId {
                   oldParentIdentifier = (oldParent == "ROOT" || oldParent == "/") ? .rootContainer : NSFileProviderItemIdentifier(oldParent)
               } else {
                   oldParentIdentifier = nil
               }
               
               if let current = originalVfsItem, !current.isDirectory { try self.validateBaseVersion(version, item: current) }
               // Handle moving item to Trash
               if parentItemIdentifier == .trashContainer {
                   logInfo(.fileOps, "🗑️ reparentItem to .trashContainer -> trashing item: \(fileId)")
                   guard let item = originalVfsItem ?? (try? self.findItem(identifier: fileId)) else {
                       completionHandler(nil, nil)
                       return
                   }
                   
                   // Guard against accidental destruction of Cryptomator vault critical files
                   let protectedNames: Set<String> = ["masterkey.cryptomator", "masterkey.bkup", "vault.cryptomator", "dirid.c9r"]
                   if protectedNames.contains(item.name.lowercased()) {
                       logError(.system, "🛡️ Blocked trashing of protected Cryptomator vault file: \(item.name)")
                       throw NSFileProviderError(.deletionRejected)
                   }
                   logInfo(.fileOps, "🔥 reparentItem to .trashContainer -> Deleting item: \(item.name) (\(fileId))")
                   if item.isDirectory { try self.preserveLocalEditBeforeDeletion(item, fileId: fileId) }
                   let baseline = try self.syncManager.getMetadataPersistent(fileId: fileId)
                   let remotePath = item.remotePath ?? baseline?.remotePath ?? ""
                   if !remotePath.isEmpty && baseline?.syncStatus != .localOnly {
                       var tombstone = baseline ?? FileMetadata(fileId: fileId, name: item.name, parentId: item.parentId, isDirectory: item.isDirectory, syncStatus: .pendingDelete, remotePath: remotePath, size: item.size)
                       if !item.isDirectory && (baseline?.syncStatus.protectsLocalChanges == true || self.syncManager.hasPendingUpload(fileId: fileId)) {
                           let source = baseline?.localPath.map { URL(fileURLWithPath: $0) } ?? self.cacheManager.localPath(for: fileId)
                           let backups = DeletedPayloadBackupStore(vaultId: self.currentVaultIdentifier)
                           let backup = try backups.preserve(source: source, fileId: fileId, name: item.name, parentId: item.parentId, remotePath: remotePath, expectedETag: baseline?.etag)
                           tombstone.localPath = try backups.payload(for: backup.id, verifyIntegrity: false).path
                       }
                       tombstone.syncStatus = .pendingDelete
                       try self.syncManager.updateMetadataPersistent(tombstone)
                       try self.syncManager.enqueuePersistent(.deleteItem(
                           fileId: fileId,
                           remotePath: remotePath,
                           isDirectory: item.isDirectory,
                           directoryId: item.isDirectory && self.vfs.isEncrypted ? fileId : nil,
                           vaultId: self.currentVaultIdentifier
                       ))
                   }
                   self.vfs.deleteFromLocalDatabaseOnly(itemId: fileId)
                   if item.isDirectory {
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
                       identifier: identifier,
                       parentIdentifier: .trashContainer,
                       filename: item.name,
                       contentType: item.isDirectory ? .folder : .data,
                       capabilities: [.allowsReading, .allowsDeleting, .allowsReparenting],
                       documentSize: item.size > 0 ? item.size : nil,
                       contentModificationDate: item.modifiedAt,
                       creationDate: item.modifiedAt,
                       isEncrypted: self.vfs.isEncrypted
                   )
                   progress.completedUnitCount = 100
                   completionHandler(trashedItem, nil)
                   return
               }
               
               if let current = originalVfsItem { try self.validateBaseVersion(version, item: current) }
               let targetParentId = parentItemIdentifier.rawValue
               let actualTargetParentId: String
               if targetParentId == NSFileProviderItemIdentifier.rootContainer.rawValue {
                   actualTargetParentId = "ROOT"
               } else if self.vfs.isEncrypted {
                   actualTargetParentId = targetParentId
               } else {
                   actualTargetParentId = targetParentId.hasPrefix("/") ? targetParentId : "/\(targetParentId)"
               }
               
               let finalName = newName ?? originalVfsItem?.name ?? URL(fileURLWithPath: fileId).lastPathComponent
               if let existingChildren = try? self.vfs.listDirectory(directoryId: actualTargetParentId) {
                   if existingChildren.contains(where: { $0.name.localizedCaseInsensitiveCompare(finalName) == .orderedSame && $0.id != fileId }) {
                       logWarning(.fileOps, "⚠️ FileProvider.reparentItem: Filename collision detected: \(finalName) in parent \(actualTargetParentId)")
                       throw NSFileProviderError(.filenameCollision)
                   }
               }
               
               logInfo(.fileOps, "📁 FileProvider.reparentItem: Starting reparentItem")
               logInfo(.fileOps, "   Source file ID: \(fileId)")
               logInfo(.fileOps, "   Target parent ID: \(actualTargetParentId)")
               logInfo(.fileOps, "   Final name: \(finalName)")
               
               let operationId = operationManager.addOperation(
                   type: .move,
                   fileName: finalName,
                   filePath: actualTargetParentId
               )
               
               let vfsItem = try await self.vfs.moveItem(
                   itemId: fileId,
                   newParentId: actualTargetParentId,
                   newName: newName
               )
               
               operationManager.updateOperation(id: operationId, status: .completed)
               
               logSuccess(.fileOps, "✅ FileProvider: VFS move/rename succeeded")
               logInfo(.fileOps, "   Returned VFS item ID: \(vfsItem.id)")
               logInfo(.fileOps, "   Returned VFS item name: \(vfsItem.name)")
               
               progress.completedUnitCount = 100
               
               let item = self.makeItem(vfsItem: vfsItem, isEncrypted: self.vfs.isEncrypted)
               
               // Notify host app that file has changed
               if let vaultId = self.vaultInfo?.id {
                   logInfo(.sync, "📤 Sending file moved/renamed notification - Vault: \(vaultId), File: \(vfsItem.id)")
                   self.sync.notifyFileChanged(vaultId: vaultId, fileId: vfsItem.id)
                   logSuccess(.sync, "✅ File move/rename notification sent")
               } else {
                   logWarning(.sync, "⚠️ No vault info, unable to send notification")
               }
               
               logSuccess(.fileOps, "✅ Item move/rename completed: \(finalName)")
               self.signalEnumeratorDebounced(for: parentItemIdentifier)
               if let oldParent = oldParentIdentifier, oldParent != parentItemIdentifier {
                   self.signalEnumeratorDebounced(for: oldParent)
               }
               self.signalEnumeratorDebounced(for: .workingSet)
               completionHandler(item, nil)
               
           } catch is CancellationError {
               completionHandler(nil, CocoaError(.userCancelled))
           } catch let error as VFSError {
               logError(.fileOps, "❌ FileProvider: VFSError in reparentItem: \(error)")
               let fpError = mapToFileProviderError(error)
               progress.completedUnitCount = 100
               completionHandler(nil, fpError)
           } catch let error as NSFileProviderError {
               logError(.fileOps, "❌ FileProvider: NSFileProviderError in reparentItem: \(error)")
               progress.completedUnitCount = 100
               completionHandler(nil, error)
           } catch {
               logError(.fileOps, "❌ FileProvider: Unknown error in reparentItem: \(error)")
               let fpError = mapToFileProviderError(error)
               progress.completedUnitCount = 100
               completionHandler(nil, fpError)
           }
       }
        progress.cancellationHandler = { task.cancel() }
    return progress
   }
}
