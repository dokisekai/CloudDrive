import Foundation

/// Vault operations needed by durable replay. The vault module owns implementation.
/// References are weak: a locked or released vault must not be kept alive by sync.
public protocol SyncVaultAccess: AnyObject {
    var vaultId: String? { get }
    var isEncrypted: Bool { get }
    func uploadFile(localURL: URL, name: String, parentId: String, expectedETag: String?) async throws -> VirtualFileItem
    func deleteRemoteItem(remotePath: String, directoryId: String?) async throws
    func deleteFromLocalDatabaseOnly(itemId: String)
    func createDirectory(name: String, parentId: String, directoryId: String) async throws -> VirtualFileItem
    func reconcileOfflineItem(oldId: String, item: VirtualFileItem)
}
