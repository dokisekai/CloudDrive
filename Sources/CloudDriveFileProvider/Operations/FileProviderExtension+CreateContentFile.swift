import Foundation
import FileProvider
import UniformTypeIdentifiers
import CloudDriveCore

extension FileProviderExtension {
    func handleCreateContentFile(itemTemplate: NSFileProviderItem, actualParentId: String, url: URL, progress: Progress, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) async throws {
        logInfo(.fileOps, "📄 FileProvider: Creating file (asynchronous queue mode)")
        logInfo(.fileOps, "   Filename: \(itemTemplate.filename)")
        logInfo(.fileOps, "   Source path: \(url.path)")
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        logInfo(.fileOps, "   File size: \(fileSize) bytes")
        
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
        
        // 1. Stage locally in pending_uploads for background sync queue worker
        let savedLocalURL = try PendingContentStager(vaultId: currentVaultIdentifier).stage(url, filename: itemTemplate.filename)
        let effectiveLocalPath = savedLocalURL.path
        
        // 2. Cache in local CacheManager so subsequent reads succeed immediately
        try? self.cacheManager.cacheFile(fileId: fileId, from: url, policy: .automatic)
        
        // 3. Record in local VFS database so getItem & listDirectory will return it immediately
        self.vfs.recordOfflineFile(
            id: fileId,
            name: itemTemplate.filename,
            parentId: actualParentId,
            size: fileSize,
            remotePath: remotePath
        )
        
        // 4. Register in SyncManager with pendingUpload status
        self.syncManager.updateMetadata(FileMetadata(
            fileId: fileId,
            name: itemTemplate.filename,
            parentId: actualParentId,
            isDirectory: false,
            syncStatus: .pendingUpload,
            localPath: self.cacheManager.localPath(for: fileId).path,
            remotePath: remotePath,
            size: fileSize,
            localModifiedAt: Date(),
            remoteModifiedAt: Date(),
            downloadProgress: 1.0
        ))
        
        // 5. Construct item and complete Finder operation IMMEDIATELY (no blocking)
        let item = self.makeItem(
            identifier: NSFileProviderItemIdentifier(fileId),
            parentIdentifier: itemTemplate.parentItemIdentifier,
            filename: itemTemplate.filename,
            contentType: itemTemplate.contentType ?? .data,
            capabilities: [.allowsReading, .allowsWriting, .allowsRenaming, .allowsDeleting, .allowsReparenting],
            documentSize: fileSize as Int64?,
            contentModificationDate: Date(),
            creationDate: Date()
        )
        progress.completedUnitCount = 100
        self.signalEnumeratorDebounced(for: itemTemplate.parentItemIdentifier)
        self.signalEnumeratorDebounced(for: .workingSet)
        // Persist before completing: the input URL is unlinked by the system at completion.
        // 6. Queue asynchronous upload via SyncManager
        if self.vfs.isEncrypted {
            try self.syncManager.enqueuePersistent(.encryptedUpload(
                fileId: fileId,
                fileName: itemTemplate.filename,
                parentId: actualParentId,
                localPath: effectiveLocalPath,
                vaultId: self.currentVaultIdentifier
            ))
        } else {
            try self.syncManager.enqueuePersistent(.upload(
                fileId: fileId,
                localPath: effectiveLocalPath,
                remotePath: remotePath
            ))
        }
        completionHandler(item, [], false, nil)
        logSuccess(.fileOps, "✅ createItem: File accepted locally & queued for async upload: \(itemTemplate.filename)")
    }
}
