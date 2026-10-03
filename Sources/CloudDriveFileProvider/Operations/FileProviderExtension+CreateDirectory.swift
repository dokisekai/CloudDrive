import Foundation
import FileProvider
import UniformTypeIdentifiers
import CloudDriveCore

extension FileProviderExtension {
    func handleCreateDirectory(itemTemplate: NSFileProviderItem, actualParentId: String, progress: Progress, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) async throws {
        logInfo(.fileOps, "📁 FileProvider: Creating directory")
        logInfo(.fileOps, "   Calling: vfs.createDirectory(name: \(itemTemplate.filename), parentId: \(actualParentId))")
        
        let operationId = operationManager.addOperation(
            type: .create,
            fileName: itemTemplate.filename,
            filePath: actualParentId
        )
        
        do {
            let vfsItem = try await self.vfs.createDirectory(
                name: itemTemplate.filename,
                parentId: actualParentId
            )
            
            operationManager.updateOperation(id: operationId, status: .completed)
            
            logSuccess(.fileOps, "✅ FileProvider: VFS directory creation succeeded")
            logInfo(.fileOps, "   Returned VFS item ID: \(vfsItem.id)")
            logInfo(.fileOps, "   Returned VFS item name: \(vfsItem.name)")
            
            progress.completedUnitCount = 100
            
            let item = self.makeItem(vfsItem: vfsItem, isEncrypted: self.vfs.isEncrypted)
            
            self.syncManager.updateMetadata(FileMetadata(
                fileId: vfsItem.id,
                name: vfsItem.name,
                parentId: vfsItem.parentId,
                isDirectory: true,
                syncStatus: .synced,
                remotePath: vfsItem.remotePath ?? "",
                localModifiedAt: Date(),
                remoteModifiedAt: Date()
            ))
            
            // Notify host app that file has changed
            if let vaultId = self.vaultInfo?.id {
                logInfo(.sync, "📤 Sending directory created notification - Vault: \(vaultId), Dir: \(vfsItem.id)")
                self.sync.notifyFileChanged(vaultId: vaultId, fileId: vfsItem.id)
                logSuccess(.sync, "✅ Directory creation notification sent")
            } else {
                logWarning(.sync, "⚠️ No vault info, unable to send notification")
            }
            
            logSuccess(.fileOps, "✅ Directory created: \(itemTemplate.filename)")
            self.signalEnumeratorDebounced(for: itemTemplate.parentItemIdentifier)
            self.signalEnumeratorDebounced(for: .workingSet)
            completionHandler(item, [], false, nil)
        } catch {
            try Task.checkCancellation()
            guard self.isOfflineFailure(error) else { throw error }
            logError(.fileOps, "⚠️ Directory creation failed remotely, queuing for offline creation: \(error.localizedDescription)")
            let dirId: String
            let remotePath: String
            if self.vfs.isEncrypted {
                dirId = UUID().uuidString
                guard let format = self.vfs.cryptomatorFormat else { throw VFSError.vaultLocked }
                remotePath = try format.getDirectoryRemotePath(name: itemTemplate.filename, parentDirId: format.dirIdData(from: actualParentId)).0
            } else {
                remotePath = actualParentId == "ROOT" ? "/\(itemTemplate.filename)" : "\(actualParentId)/\(itemTemplate.filename)"
                dirId = remotePath
            }
            
            self.vfs.recordOfflineDirectory(id: dirId, name: itemTemplate.filename, parentId: actualParentId, remotePath: remotePath)
            
            if self.vfs.isEncrypted {
                try self.syncManager.enqueuePersistent(.encryptedCreateDirectory(directoryId: dirId, name: itemTemplate.filename, parentId: actualParentId, remotePath: remotePath, vaultId: self.currentVaultIdentifier))
            } else {
                try self.syncManager.enqueuePersistent(.createDirectory(directoryId: dirId, name: itemTemplate.filename, parentId: actualParentId, remotePath: remotePath))
            }

            self.syncManager.updateMetadata(FileMetadata(
                fileId: dirId,
                name: itemTemplate.filename,
                parentId: actualParentId,
                isDirectory: true,
                syncStatus: .pendingUpload,
                remotePath: remotePath,
                localModifiedAt: Date(),
                remoteModifiedAt: Date()
            ))
            
            let tempItem = self.makeItem(
                identifier: NSFileProviderItemIdentifier(dirId),
                parentIdentifier: itemTemplate.parentItemIdentifier,
                filename: itemTemplate.filename,
                contentType: .folder,
                capabilities: [.allowsReading, .allowsWriting, .allowsRenaming, .allowsDeleting, .allowsReparenting, .allowsAddingSubItems, .allowsContentEnumerating],
                documentSize: nil,
                contentModificationDate: Date(),
                creationDate: Date()
            )
            
            self.signalEnumeratorDebounced(for: itemTemplate.parentItemIdentifier)
            self.signalEnumeratorDebounced(for: .workingSet)
            progress.completedUnitCount = 100
            completionHandler(tempItem, [], false, nil)
        }
        
    }
}
