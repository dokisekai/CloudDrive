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
        guard let provider = activeProvider else { throw VFSError.vaultNotFound("No active vault mounted") }
        if let encrypted = provider as? EncryptedVFSProvider {
            return try await encrypted.uploadFile(localURL: localURL, name: name, parentId: parentId, expectedETag: expectedETag)
        }
        if let direct = provider as? DirectMappingVFSProvider {
            return try await direct.uploadFile(localURL: localURL, name: name, parentId: parentId, expectedETag: expectedETag)
        }
        throw VFSError.fileOperationFailed("Conditional upload is unavailable")
    }

    public func downloadFile(fileId: String, to destinationURL: URL, progress: ((Double) -> Void)? = nil) async throws {
        guard let provider = activeProvider else {
            throw VFSError.vaultNotFound("No active vault mounted")
        }
        try await provider.downloadFile(fileId: fileId, to: destinationURL, progress: progress)
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
}
