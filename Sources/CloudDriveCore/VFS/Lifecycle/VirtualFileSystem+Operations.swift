import Foundation
import CryptomatorCryptoLib

extension VirtualFileSystem {
    public func createDirectory(name: String, parentId: String) async throws -> VirtualFileItem {
        guard let provider = activeProvider else {
            throw VFSError.vaultNotFound("No active vault mounted")
        }
        return try await provider.createDirectory(name: name, parentId: parentId)
    }

    public func createDirectory(name: String, parentId: String, directoryId: String) async throws -> VirtualFileItem {
        guard let provider = activeProvider as? EncryptedVFSProvider else {
            throw VFSError.fileOperationFailed("Encrypted directory requires an unlocked encrypted vault")
        }
        return try await provider.createDirectory(name: name, parentId: parentId, directoryId: directoryId)
    }

    public func uploadFile(localURL: URL, name: String, parentId: String) async throws -> VirtualFileItem {
        guard let provider = activeProvider else {
            throw VFSError.vaultNotFound("No active vault mounted")
        }
        return try await provider.uploadFile(localURL: localURL, name: name, parentId: parentId)
    }

    public func uploadFile(localURL: URL, name: String, parentId: String, expectedETag: String?) async throws -> VirtualFileItem {
        try await uploadFile(localURL: localURL, name: name, parentId: parentId, expectedETag: expectedETag, progress: nil)
    }

    public func uploadFile(localURL: URL, name: String, parentId: String, expectedETag: String?, progress: ((Double) -> Void)?) async throws -> VirtualFileItem {
        guard let provider = activeProvider else { throw VFSError.vaultNotFound("No active vault mounted") }
        if let encrypted = provider as? EncryptedVFSProvider {
            return try await encrypted.uploadFile(localURL: localURL, name: name, parentId: parentId, expectedETag: expectedETag, progress: progress)
        }
        if let direct = provider as? DirectMappingVFSProvider {
            return try await direct.uploadFile(localURL: localURL, name: name, parentId: parentId, expectedETag: expectedETag, progress: progress)
        }
        throw VFSError.fileOperationFailed("Conditional upload is unavailable")
    }

    public func downloadFile(fileId: String, to destinationURL: URL, progress: ((Double) -> Void)? = nil) async throws {
        guard let provider = activeProvider else {
            throw VFSError.vaultNotFound("No active vault mounted")
        }
        try await provider.downloadFile(fileId: fileId, to: destinationURL, progress: progress)
    }

    public func downloadConflictContent(fileId: String, remotePath: String, to destinationURL: URL) async throws -> String? {
        try await downloadConflictContent(fileId: fileId, remotePath: remotePath, to: destinationURL, expectedETag: nil)
    }

    public func downloadConflictContent(fileId: String, remotePath: String, to destinationURL: URL, expectedETag: String?) async throws -> String? {
        if isEncrypted {
            guard let format = cryptomatorFormat else { throw VFSError.vaultLocked }
            return try await format.downloadFile(remotePath: remotePath, to: destinationURL, expectedETag: expectedETag)
        }
        guard let storageClient else { throw VFSError.vaultNotFound("No active storage") }
        return try await storageClient.downloadFile(path: remotePath, to: destinationURL, expectedETag: expectedETag) { _ in }
    }

    public func downloadFile(fileId: String, to destinationURL: URL, expectedETag: String?, progress: ((Double) -> Void)? = nil) async throws -> String? {
        guard let provider = activeProvider else { throw VFSError.vaultNotFound("No active vault mounted") }
        return try await provider.downloadFile(fileId: fileId, to: destinationURL, expectedETag: expectedETag, progress: progress)
    }

    public func readRange(fileId: String, range: ClosedRange<Int64>) async throws -> Data {
        try await readRange(fileId: fileId, range: range, expectedETag: nil)
    }

    public func readRange(fileId: String, range: ClosedRange<Int64>, expectedETag: String?) async throws -> Data {
        guard let provider = activeProvider else { throw VFSError.vaultNotFound("No active vault mounted") }
        return try await provider.readRange(fileId: fileId, range: range, expectedETag: expectedETag)
    }

    public func delete(itemId: String) async throws {
        guard let provider = activeProvider else {
            throw VFSError.vaultNotFound("No active vault mounted")
        }
        try await provider.delete(itemId: itemId)
    }

    public func modifyFile(fileId: String, newContent: URL) async throws -> VirtualFileItem {
        guard let provider = activeProvider else {
            throw VFSError.vaultNotFound("No active vault mounted")
        }
        return try await provider.modifyFile(fileId: fileId, newContent: newContent)
    }

    public func moveItem(itemId: String, newParentId: String, newName: String? = nil) async throws -> VirtualFileItem {
        guard let provider = activeProvider else {
            throw VFSError.vaultNotFound("No active vault mounted")
        }
        return try await provider.moveItem(itemId: itemId, newParentId: newParentId, newName: newName)
    }

    public func copyItem(itemId: String, newParentId: String, newName: String? = nil) async throws -> VirtualFileItem {
        guard let provider = activeProvider else {
            throw VFSError.vaultNotFound("No active vault mounted")
        }
        return try await provider.copyItem(itemId: itemId, newParentId: newParentId, newName: newName)
    }
    public func copyItem(itemId: String, newParentId: String, newName: String?, cachedContentOverride: String, expectedSourceETag: String) async throws -> VirtualFileItem {
        guard let provider = activeProvider else { throw VFSError.vaultNotFound("No active vault mounted") }
        return try await provider.copyItem(itemId: itemId, newParentId: newParentId, newName: newName, cachedContentOverride: cachedContentOverride, expectedSourceETag: expectedSourceETag)
    }

    public func resolveRelativePath(name: String, parentId: String) -> String? {
        guard parentId != "ROOT" && parentId != "/" && !parentId.isEmpty else {
            return name
        }
        var components = [name]
        var currentParent = parentId
        var visited = Set<String>()
        while currentParent != "ROOT" && currentParent != "/" && !currentParent.isEmpty && !visited.contains(currentParent) {
            visited.insert(currentParent)
            if let dir = try? database.getDirectory(id: currentParent) {
                components.insert(dir.name, at: 0)
                currentParent = dir.parentId ?? "ROOT"
            } else {
                break
            }
        }
        return components.joined(separator: "/")
    }

}

