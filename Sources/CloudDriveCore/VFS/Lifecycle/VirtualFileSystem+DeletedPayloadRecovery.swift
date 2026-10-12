import Foundation
import CloudDriveRecovery

extension VirtualFileSystem {
    public func listDeletedPayloadBackups() throws -> [DeletedPayloadBackup] {
        guard let vaultId else { throw VFSError.storageNotConfigured }
        return try DeletedPayloadBackupStore(vaultId: vaultId).list()
    }

    @discardableResult
    public func exportDeletedPayloadBackup(id: String, to destination: URL) throws -> DeletedPayloadBackup {
        guard let vaultId else { throw VFSError.storageNotConfigured }
        return try DeletedPayloadBackupStore(vaultId: vaultId).export(id: id, to: destination)
    }

    @discardableResult
    public func cleanupExportedDeletedPayloadBackups() throws -> Int {
        guard let vaultId else { throw VFSError.storageNotConfigured }
        return try DeletedPayloadBackupStore(vaultId: vaultId).cleanupExported()
    }
}
