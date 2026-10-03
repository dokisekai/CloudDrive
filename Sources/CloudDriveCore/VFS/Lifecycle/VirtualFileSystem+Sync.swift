import Foundation
import CryptomatorCryptoLib

extension VirtualFileSystem {
    public func getNetworkStatus() -> NetworkStatus {
        return syncManager.getNetworkStatus()
    }

    public func syncDirectory(directoryId: String, localPath: String, remotePath: String) async throws -> [FileMetadata] {
        return try await syncManager.syncDirectory(directoryId: directoryId, localPath: localPath, remotePath: remotePath)
    }

    public func getPendingSyncCount() -> Int {
        return syncManager.getSyncQueueCount()
    }

    public func processSyncQueue() {
        syncManager.processSyncQueue()
    }

    public func deleteRemoteItem(remotePath: String, directoryId: String?) async throws {
        guard let client = storageClient else { throw VFSError.storageNotConfigured }
        if isEncrypted {
            guard let format = cryptomatorFormat else { throw VFSError.vaultLocked }
            let dirData = directoryId.map { format.dirIdData(from: $0) }
            try await format.deleteItem(remotePath: remotePath, dirIdData: dirData)
        } else {
            try await client.delete(path: remotePath)
        }
    }

    public func reconcileOfflineItem(oldId: String, item: VirtualFileItem) {
        guard oldId != item.id else { return }
        if item.isDirectory { try? database.deleteDirectory(id: oldId) }
        else { try? database.deleteFile(id: oldId) }
        try? cacheManager.moveCache(from: oldId, to: item.id)
        syncManager.moveMetadata(from: oldId, to: item.id, newParentId: item.parentId,
            newName: item.name, newRemotePath: item.remotePath ?? item.id, fallbackStatus: .pendingUpload)
    }
}
