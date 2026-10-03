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
               
               // Handle moving item to Trash
               if parentItemIdentifier == .trashContainer {
                   logInfo(.fileOps, "🗑️ reparentItem to .trashContainer -> trashing item: \(fileId)")
                   guard let item = originalVfsItem ?? (try? self.findItem(identifier: fileId)) else {
                       completionHandler(nil, nil)
                       return
                   }
                   let isRecycleBinFolder = self.vfs.isRecycleBinDirectory(id: item.id)
                   let isAlreadyInBin = self.vfs.isItemInRecycleBin(item: item)
                   let isBinEnabled = RecycleBinConfig.isEnabled(for: self.currentVaultIdentifier)
                   
                   if isRecycleBinFolder {
                       logInfo(.fileOps, "🧹 reparentItem: Trashing Recycle Bin folder itself -> emptying trash")
                       try await self.vfs.emptyTrash()
                       self.signalEnumeratorDebounced(for: .rootContainer)
                       if let bin = self.vfs.getRecycleBinDirectory() {
                           self.signalEnumeratorDebounced(for: NSFileProviderItemIdentifier(bin.id))
                       }
                       self.signalEnumeratorDebounced(for: .workingSet)
                   } else if isBinEnabled && !isAlreadyInBin {
                       logInfo(.fileOps, "🗑️ reparentItem to .trashContainer -> Soft-deleting to RecycleBin folder: \(item.name) (\(fileId))")
                       _ = try await self.vfs.moveToRecycleBin(item: item)
                       if let oldParent = oldParentIdentifier {
                           self.signalEnumeratorDebounced(for: oldParent)
                       }
                       if let bin = self.vfs.getRecycleBinDirectory() {
                           self.signalEnumeratorDebounced(for: NSFileProviderItemIdentifier(bin.id))
                       }
                       self.signalEnumeratorDebounced(for: .workingSet)
                   } else {
                       logInfo(.fileOps, "🔥 reparentItem to .trashContainer -> Permanently deleting item: \(item.name) (\(fileId)) (isInRecycleBin=\(isAlreadyInBin), isBinEnabled=\(isBinEnabled))")
                       let baseline = self.syncManager.getMetadata(fileId: fileId)
                       let remotePath = item.remotePath ?? baseline?.remotePath ?? ""
                       if !remotePath.isEmpty {
                           try? self.syncManager.enqueuePersistent(.deleteItem(
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
                       try? RecycleBinStore.shared.deleteByFileId(fileId: fileId)
                       if let oldParent = oldParentIdentifier {
                           self.signalEnumeratorDebounced(for: oldParent)
                       }
                       self.signalEnumeratorDebounced(for: .workingSet)
                   }
                   
                   let trashedItem = self.makeItem(
                       identifier: identifier,
                       parentIdentifier: .trashContainer,
                       filename: item.name,
                       contentType: item.isDirectory ? .folder : .data,
                       capabilities: [.allowsReading, .allowsDeleting],
                       documentSize: item.size > 0 ? item.size : nil,
                       contentModificationDate: item.modifiedAt,
                       creationDate: item.modifiedAt,
                       isEncrypted: self.vfs.isEncrypted
                   )
                   progress.completedUnitCount = 100
                   completionHandler(trashedItem, nil)
                   return
               }
               
               if let current = originalVfsItem { try? self.validateBaseVersion(version, item: current) }
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
               
               let isMovingIntoBin = self.vfs.isRecycleBinDirectory(id: actualTargetParentId)
               let wasInBin = (originalVfsItem != nil && self.vfs.isItemInRecycleBin(item: originalVfsItem!))
               
               if isMovingIntoBin {
                   if !vfsItem.isDirectory {
                       try? self.cacheManager.removeCachedFile(fileId: vfsItem.id)
                       try? self.cacheManager.removeCachedFile(fileId: fileId)
                   } else {
                       self.cacheManager.removeDirectoryCache(forDirectoryPrefix: vfsItem.id)
                       self.cacheManager.removeDirectoryCache(forDirectoryPrefix: fileId)
                   }
                   if var meta = self.syncManager.getMetadata(fileId: vfsItem.id) {
                       meta.localPath = nil
                       meta.syncStatus = .cloudOnly
                       self.syncManager.updateMetadata(meta)
                   }
                   let binItem = RecycleBinItem(
                       id: UUID().uuidString,
                       vaultId: self.currentVaultIdentifier,
                       fileId: vfsItem.id,
                       name: vfsItem.name,
                       originalParentId: originalVfsItem?.parentId ?? "ROOT",
                       originalRemotePath: originalVfsItem?.remotePath ?? "",
                       isDirectory: vfsItem.isDirectory,
                       size: vfsItem.size,
                       deletedAt: Date(),
                       localBackupPath: nil
                   )
                   try? RecycleBinStore.shared.save(binItem)
                   logInfo(.fileOps, "🗑️ reparentItem: Dragged into Recycle Bin -> local cache purged, marked cloudOnly")
               } else if wasInBin {
                   try? RecycleBinStore.shared.deleteByFileId(fileId: fileId)
                   try? RecycleBinStore.shared.deleteByFileId(fileId: vfsItem.id)
                   logInfo(.fileOps, "♻️ reparentItem: Dragged out of Recycle Bin -> restored")
               }
               
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
               let fpError = NSFileProviderError(.cannotSynchronize)
               progress.completedUnitCount = 100
               completionHandler(nil, fpError)
           }
       }
        progress.cancellationHandler = { task.cancel() }
    return progress
   }
}
