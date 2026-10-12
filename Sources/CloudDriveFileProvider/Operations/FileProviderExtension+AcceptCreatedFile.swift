import Foundation
import FileProvider
import CloudDriveCore

extension FileProviderExtension {
    /// Accept exactly one immutable input generation before publishing it to Finder.
    func createdFileDestination(itemTemplate: NSFileProviderItem, parentId: String) throws -> (fileId: String, remotePath: String, excluded: Bool) {
        let fileId: String
        let remotePath: String
        if vfs.isEncrypted {
            guard let format = vfs.cryptomatorFormat else { throw VFSError.vaultLocked }
            let (path, _, encryptedName, _) = try format.getFileRemotePath(name: itemTemplate.filename, parentDirId: format.dirIdData(from: parentId))
            fileId = "file_\(encryptedName)"
            remotePath = path
        } else {
            let parent: String
            if parentId == "ROOT" || parentId == "/" { parent = vaultInfo?.storagePath ?? "/" }
            else { parent = (try vfs.database.getDirectory(id: parentId))?.remotePath ?? parentId }
            let normalized = parent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            remotePath = normalized.isEmpty ? "/" + itemTemplate.filename : "/" + normalized + "/" + itemTemplate.filename
            fileId = remotePath
        }
        let checkPath = parentId == "ROOT" ? itemTemplate.filename : "\(parentId)/\(itemTemplate.filename)"
        let excluded = itemTemplate.filename.hasSuffix(".nosync")
            || IgnoreRuleEngine.shared.shouldIgnore(path: checkPath, name: itemTemplate.filename, isDirectory: false, vaultId: currentVaultIdentifier)
            || IgnoreRuleEngine.shared.isUserExcluded(vaultId: currentVaultIdentifier, path: itemTemplate.filename)
            || IgnoreRuleEngine.shared.isUserExcluded(vaultId: currentVaultIdentifier, path: checkPath)
            || IgnoreRuleEngine.shared.shouldIgnore(path: remotePath, name: itemTemplate.filename, isDirectory: false, vaultId: currentVaultIdentifier)
        return (fileId, remotePath, excluded)
    }

    func acceptCreatedFile(itemTemplate: NSFileProviderItem, parentId: String, staged: URL, preparedCacheId: String? = nil) throws -> FileProviderItem {
        let (fileId, remotePath, excluded) = try createdFileDestination(itemTemplate: itemTemplate, parentId: parentId)
        let size = Int64(try staged.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let status: SyncStatus = excluded ? .localOnly : .pendingUpload
        let accepted = FileMetadata(fileId: fileId, name: itemTemplate.filename, parentId: parentId, isDirectory: false,
            syncStatus: status, localPath: staged.path, remotePath: remotePath, size: size, localModifiedAt: Date(), downloadProgress: 1)
        let operation: SyncOperation?
        if excluded { operation = nil }
        else if vfs.isEncrypted { operation = .encryptedUpload(fileId: fileId, fileName: itemTemplate.filename, parentId: parentId, localPath: staged.path, vaultId: currentVaultIdentifier) }
        else { operation = .upload(fileId: fileId, localPath: staged.path, remotePath: remotePath) }
        try syncManager.withJournalCommit {
            try syncManager.acceptSavePersistent(metadata: accepted, operation: operation, expectedETag: nil) {
                guard try self.syncManager.getMetadataPersistent(fileId: fileId) == nil,
                      !self.syncManager.hasPendingOperation(fileId: fileId) else { throw NSFileProviderError(.filenameCollision) }
            }
            // Publish the same snapshot, not the system URL which can change or disappear.
            do {
                if let preparedCacheId {
                    try cacheManager.cloneCache(from: preparedCacheId, to: fileId)
                    if let modifiedAt = accepted.localModifiedAt { cacheManager.bindAcceptedGeneration(fileId: fileId, modifiedAt: modifiedAt) }
                } else {
                    try cacheManager.cacheFile(fileId: fileId, from: staged, policy: .automatic)
                }
                var cached = accepted
                cached.localPath = cacheManager.localPath(for: fileId).path
                try syncManager.updateMetadataPersistent(cached)
            } catch { logWarning(.sync, "Created file retained in immutable staging: \(error.localizedDescription)") }
            vfs.recordOfflineFile(id: fileId, name: itemTemplate.filename, parentId: parentId, size: size, remotePath: remotePath)
        }
        return makeItem(vfsItem: VirtualFileItem(id: fileId, name: itemTemplate.filename, isDirectory: false, size: size,
            modifiedAt: accepted.localModifiedAt ?? Date(), parentId: parentId, syncStatus: status,
            localPath: accepted.localPath, remotePath: remotePath), isEncrypted: vfs.isEncrypted)
    }
}
