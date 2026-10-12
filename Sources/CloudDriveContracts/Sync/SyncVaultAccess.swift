import Foundation

/// Vault operations needed by durable replay. The vault module owns implementation.
/// References are weak: a locked or released vault must not be kept alive by sync.
public protocol SyncVaultAccess: AnyObject {
    var vaultId: String? { get }
    var isEncrypted: Bool { get }
    func uploadFile(localURL: URL, name: String, parentId: String, expectedETag: String?, progress: ((Double) -> Void)?) async throws -> VirtualFileItem
    func deleteRemoteItem(remotePath: String, directoryId: String?) async throws
    func deleteRemoteItem(remotePath: String, directoryId: String?, expectedETag: String?) async throws
    func deleteFromLocalDatabaseOnly(itemId: String)
    func downloadFile(fileId: String, to destinationURL: URL, progress: ((Double) -> Void)?) async throws
    /// Download conflict content without changing metadata, returning its actual revision.
    func downloadConflictContent(fileId: String, remotePath: String, to destinationURL: URL) async throws -> String?
    func createDirectory(name: String, parentId: String, directoryId: String) async throws -> VirtualFileItem
    func reconcileOfflineItem(oldId: String, item: VirtualFileItem)
    func resolveRelativePath(name: String, parentId: String) -> String?
}

public extension SyncVaultAccess {
    func resolveRelativePath(name: String, parentId: String) -> String? {
        return nil
    }
    func downloadConflictContent(fileId: String, remotePath: String, to destinationURL: URL) async throws -> String? {
        try await downloadFile(fileId: fileId, to: destinationURL, progress: nil)
        return nil
    }
    func deleteRemoteItem(remotePath: String, directoryId: String?, expectedETag: String?) async throws {
        throw StorageError.notSupported("Version-aware vault deletion is unavailable")
    }

    func uploadFile(localURL: URL, name: String, parentId: String, expectedETag: String?) async throws -> VirtualFileItem {
        try await uploadFile(localURL: localURL, name: name, parentId: parentId, expectedETag: expectedETag, progress: nil)
    }
    
    func downloadFile(fileId: String, to destinationURL: URL) async throws {
        try await downloadFile(fileId: fileId, to: destinationURL, progress: nil)
    }
}
