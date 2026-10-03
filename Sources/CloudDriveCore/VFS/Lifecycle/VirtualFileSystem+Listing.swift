import Foundation
import CryptomatorCryptoLib

extension VirtualFileSystem {
    public func getItem(id: String) throws -> VirtualFileItem? {
        if let provider = activeProvider {
            return try provider.getItem(id: id)
        }
        return try fallbackGetItem(id: id)
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
            return cachedItems
        }
        
        if let provider = activeProvider {
            let semaphore = DispatchSemaphore(value: 0)
            var resultItems: [VirtualFileItem] = []
            var caughtError: Error?
            Task {
                do {
                    resultItems = try await provider.listDirectory(directoryId: directoryId, forceRefresh: true)
                } catch {
                    caughtError = error
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 15.0)
            if let err = caughtError {
                throw err
            }
            return resultItems
        }
        
        return cachedItems
    }

    public func listDirectoryFromWebDAVAsync(directoryId: String) async throws -> [VirtualFileItem] {
        guard let provider = activeProvider else {
            throw VFSError.vaultNotFound("No active vault mounted")
        }
        return try await provider.listDirectory(directoryId: directoryId, forceRefresh: true)
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
