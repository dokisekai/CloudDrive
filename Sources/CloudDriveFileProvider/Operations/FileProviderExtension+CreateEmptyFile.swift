import Foundation
import FileProvider
import UniformTypeIdentifiers
import CloudDriveCore

extension FileProviderExtension {
    func handleCreateEmptyFile(itemTemplate: NSFileProviderItem, actualParentId: String, options: NSFileProviderCreateItemOptions, progress: Progress, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) async throws {
        // 1. If options indicate item may already exist, attempt matching with existing remote/local item
        if options.contains(.mayAlreadyExist) {
            logInfo(.fileOps, "ℹ️ FileProvider.createItem: mayAlreadyExist option present with nil url, matching existing item...")
            if let existing = try? self.vfs.listDirectory(directoryId: actualParentId).first(where: { $0.name == itemTemplate.filename }) {
                let item = self.makeItem(vfsItem: existing, isEncrypted: self.vfs.isEncrypted)
                progress.completedUnitCount = 100
                completionHandler(item, [], false, nil)
                return
            } else {
                progress.completedUnitCount = 100
                completionHandler(nil, [], false, nil)
                return
            }
        }
        
        // 2. Otherwise create empty 0-byte file (asynchronous queue mode)
        logInfo(.fileOps, "📄 FileProvider.createItem: Creating empty 0-byte file: \(itemTemplate.filename)")
        let savedEmptyURL = try PendingContentStager(vaultId: currentVaultIdentifier).stageEmpty(filename: itemTemplate.filename)

        let fileId: String
        let remotePath: String
        if self.vfs.isEncrypted {
            if let format = self.vfs.cryptomatorFormat,
               let (fileC9rPath, _, encName, _) = try? format.getFileRemotePath(name: itemTemplate.filename, parentDirId: format.dirIdData(from: actualParentId)) {
                fileId = "file_\(encName)"
                remotePath = fileC9rPath
            } else {
                fileId = "pending_\(UUID().uuidString.prefix(8))_\(itemTemplate.filename)"
                remotePath = fileId
            }
        } else {
            if actualParentId == "ROOT" {
                remotePath = "/\(itemTemplate.filename)"
            } else if actualParentId.hasSuffix("/") {
                remotePath = "\(actualParentId)\(itemTemplate.filename)"
            } else {
                remotePath = "\(actualParentId)/\(itemTemplate.filename)"
            }
            fileId = remotePath
        }
        
        try? self.cacheManager.cacheFile(fileId: fileId, from: savedEmptyURL, policy: .automatic)
        
        self.vfs.recordOfflineFile(
            id: fileId,
            name: itemTemplate.filename,
            parentId: actualParentId,
            size: 0,
            remotePath: remotePath
        )
        
        self.syncManager.updateMetadata(FileMetadata(
            fileId: fileId,
            name: itemTemplate.filename,
            parentId: actualParentId,
            isDirectory: false,
            syncStatus: .pendingUpload,
            localPath: self.cacheManager.localPath(for: fileId).path,
            remotePath: remotePath,
            size: 0,
            localModifiedAt: Date(),
            remoteModifiedAt: Date(),
            downloadProgress: 1.0
        ))
        
        let item = self.makeItem(
            identifier: NSFileProviderItemIdentifier(fileId),
            parentIdentifier: itemTemplate.parentItemIdentifier,
            filename: itemTemplate.filename,
            contentType: itemTemplate.contentType ?? .data,
            capabilities: [.allowsReading, .allowsWriting, .allowsRenaming, .allowsDeleting, .allowsReparenting],
            documentSize: 0,
            contentModificationDate: Date(),
            creationDate: Date()
        )
        self.signalEnumeratorDebounced(for: itemTemplate.parentItemIdentifier)
        self.signalEnumeratorDebounced(for: .workingSet)
        progress.completedUnitCount = 100
        if self.vfs.isEncrypted {
            try self.syncManager.enqueuePersistent(.encryptedUpload(
                fileId: fileId,
                fileName: itemTemplate.filename,
                parentId: actualParentId,
                localPath: savedEmptyURL.path,
                vaultId: self.currentVaultIdentifier
            ))
        } else {
            try self.syncManager.enqueuePersistent(.upload(
                fileId: fileId,
                localPath: savedEmptyURL.path,
                remotePath: remotePath
            ))
        }
        completionHandler(item, [], false, nil)
        logSuccess(.fileOps, "✅ createItem: Empty file created locally & queued for async upload: \(itemTemplate.filename)")
    }
}
