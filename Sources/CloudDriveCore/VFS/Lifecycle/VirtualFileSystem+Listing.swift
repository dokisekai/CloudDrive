import Foundation
import CryptomatorCryptoLib
import CloudDriveContracts

private final class DirectoryListingResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<[VirtualFileItem], Error>?
    func store(_ value: Result<[VirtualFileItem], Error>) { lock.withLock { result = value } }
    func take() -> Result<[VirtualFileItem], Error>? { lock.withLock { result } }
}

extension VirtualFileSystem {
    public func getItem(id: String) throws -> VirtualFileItem? {
        if let provider = activeProvider {
            return try provider.getItem(id: id).map { try applyingPersistentSyncState($0) }
        }
        return try fallbackGetItem(id: id).map { try applyingPersistentSyncState($0) }
    }

    func fallbackGetItem(id: String) throws -> VirtualFileItem? {
        var dirRecord = try? database.getDirectory(id: id)
        if dirRecord == nil && !id.hasPrefix("/") {
            dirRecord = try? database.getDirectory(id: "/\(id)")
        } else if dirRecord == nil && id.hasPrefix("/") {
            dirRecord = try? database.getDirectory(id: String(id.dropFirst()))
        }
        if let dir = dirRecord {
            return VirtualFileItem(
                id: dir.id,
                name: dir.name,
                isDirectory: true,
                size: 0,
                modifiedAt: dir.modifiedAt,
                parentId: dir.parentId ?? rootId,
                syncStatus: .synced,
                remotePath: dir.remotePath.isEmpty ? dir.id : dir.remotePath
            )
        }
        
        var fileRecord = try? database.getFile(id: id)
        if fileRecord == nil && !id.hasPrefix("file_") {
            fileRecord = try? database.getFile(id: "file_\(id)")
        }
        if fileRecord == nil && !id.hasPrefix("/") {
            fileRecord = try? database.getFile(id: "/\(id)")
        } else if fileRecord == nil && id.hasPrefix("/") {
            fileRecord = try? database.getFile(id: String(id.dropFirst()))
        }
        if let file = fileRecord {
            return VirtualFileItem(
                id: file.id,
                name: file.name,
                isDirectory: false,
                size: file.size,
                modifiedAt: file.modifiedAt,
                parentId: file.parentId,
                syncStatus: .synced,
                remotePath: file.remotePath.isEmpty ? file.id : file.remotePath
            )
        }
        return nil
    }

    public func listDirectory(directoryId: String) throws -> [VirtualFileItem] {
        let cachedItems = (try? database.listChildren(parentId: directoryId)) ?? []
        
        directoryCacheLock.lock()
        let lastFetch = directoryCacheTimestamps[directoryId]
        let isStale = lastFetch == nil || Date().timeIntervalSince(lastFetch!) > directoryCacheTTL
        directoryCacheLock.unlock()
        
        if !cachedItems.isEmpty {
            if isStale {
                Task { [weak self] in
                    _ = try? await self?.listDirectoryFromWebDAVAsync(directoryId: directoryId)
                }
            }
            return try cachedItems.map { try applyingPersistentSyncState($0) }
        }
        
        if let provider = activeProvider {
            let semaphore = DispatchSemaphore(value: 0)
            let box = DirectoryListingResultBox()
            let task = Task.detached {
                do { box.store(.success(try await provider.listDirectory(directoryId: directoryId, forceRefresh: true))) }
                catch { box.store(.failure(error)) }
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 15.0) == .success else {
                task.cancel()
                throw VFSError.fileOperationFailed("Directory listing timed out")
            }
            guard currentVaultId == provider.vaultId, let result = box.take() else { throw VFSError.vaultNotFound("Vault changed during listing") }
            let resultItems = try result.get()
            directoryCacheLock.withLock { directoryCacheTimestamps[directoryId] = Date() }
            return try resultItems.map { try applyingPersistentSyncState($0) }
        }

        return try cachedItems.map { try applyingPersistentSyncState($0) }
    }

    public func listDirectoryFromWebDAVAsync(directoryId: String) async throws -> [VirtualFileItem] {
        guard let provider = activeProvider else {
            throw VFSError.vaultNotFound("No active vault mounted")
        }
        let items = try await provider.listDirectory(directoryId: directoryId, forceRefresh: true)
        guard currentVaultId == provider.vaultId else { throw VFSError.vaultNotFound("Vault changed during listing") }
        directoryCacheLock.withLock { directoryCacheTimestamps[directoryId] = Date() }
        return try items.map { try applyingPersistentSyncState($0) }
    }

    /// Cached database listings contain remote structure, not live sync state.
    /// Overlay durable metadata without treating an arbitrary cache file as proof
    /// that the current remote revision has been downloaded.
    func applyingPersistentSyncState(_ item: VirtualFileItem) throws -> VirtualFileItem {
        let meta = try syncManager.getMetadataPersistent(fileId: item.id)
        let isCached = cacheManager.isCached(fileId: item.id)
        let cachePath = isCached ? cacheManager.localPath(for: item.id).path : nil
        return Self.itemByApplyingSyncMetadata(item, metadata: meta, isCached: isCached, cacheLocalPath: cachePath)
    }

    static func itemByApplyingSyncMetadata(_ item: VirtualFileItem, metadata: FileMetadata?, isCached: Bool = false, cacheLocalPath: String? = nil) -> VirtualFileItem {
        if let metadata {
            let fileExistsAtLocalPath = metadata.localPath.map { FileManager.default.fileExists(atPath: $0) } == true
            let localAvailable = item.isDirectory || fileExistsAtLocalPath || isCached
            let status = metadata.syncStatus == .synced && !localAvailable ? SyncStatus.cloudOnly : metadata.syncStatus
            let protects = status.protectsLocalChanges
            let effectiveLocalPath = fileExistsAtLocalPath ? metadata.localPath : (cacheLocalPath ?? metadata.localPath)
            return VirtualFileItem(id: item.id, name: protects ? metadata.name : item.name, isDirectory: item.isDirectory,
                size: protects ? metadata.size : item.size, modifiedAt: protects ? (metadata.localModifiedAt ?? item.modifiedAt) : item.modifiedAt,
                parentId: protects ? metadata.parentId : item.parentId, syncStatus: status,
                localPath: effectiveLocalPath, remotePath: metadata.remotePath ?? item.remotePath, etag: protects ? metadata.etag : (metadata.remoteETag ?? item.etag ?? metadata.etag))
        }
        let localAvailable = item.isDirectory || isCached
        return VirtualFileItem(id: item.id, name: item.name, isDirectory: item.isDirectory, size: item.size,
            modifiedAt: item.modifiedAt, parentId: item.parentId, syncStatus: localAvailable ? .synced : .cloudOnly,
            localPath: cacheLocalPath, remotePath: item.remotePath, etag: item.etag)
    }

    public func invalidateDirectoryCache(directoryId: String? = nil) {
        directoryCacheLock.lock()
        if let dirId = directoryId {
            directoryCacheTimestamps.removeValue(forKey: dirId)
        } else {
            directoryCacheTimestamps.removeAll()
        }
        directoryCacheLock.unlock()
        activeProvider?.invalidateDirectoryCache(directoryId: directoryId)
    }
}
