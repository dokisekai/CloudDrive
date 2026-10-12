import Foundation
import FileProvider
import CloudDriveCore
import CloudDriveRecovery

extension FileProviderExtension {
    /// Soft deletion and moving into the bin must preserve an uncommitted edit
    /// independently of cache eviction and eventual remote queue completion.
    @discardableResult
    func preserveLocalEditBeforeDeletion(_ item: VirtualFileItem, fileId: String) throws -> URL? {
        if item.isDirectory {
            var pending = [item]
            var visited = Set<String>()
            while let directory = pending.popLast() {
                guard visited.insert(directory.id).inserted else { throw StorageError.invalidOperation }
                for child in try vfs.database.listChildren(parentId: directory.id) {
                    if child.isDirectory { pending.append(child) }
                    else { try preserveLocalEditBeforeDeletion(child, fileId: child.id) }
                }
            }
            return nil
        }
        let baseline = try syncManager.getMetadataPersistent(fileId: fileId)
        guard baseline?.syncStatus.protectsLocalChanges == true || syncManager.hasPendingUpload(fileId: fileId) else { return nil }
        let source = baseline?.localPath.map { URL(fileURLWithPath: $0) } ?? cacheManager.localPath(for: fileId)
        let store = DeletedPayloadBackupStore(vaultId: currentVaultIdentifier)
        let backup = try store.preserve(source: source, fileId: fileId, name: item.name, parentId: item.parentId, remotePath: item.remotePath ?? baseline?.remotePath, expectedETag: baseline?.etag)
        return try store.payload(for: backup.id, verifyIntegrity: false)
    }
}
