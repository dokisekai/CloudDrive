import Foundation
import FileProvider
import CloudDriveCore

extension FileProviderExtension {
    func thumbnailIdentifier(_ id: String) -> String {
        let vault = currentVaultIdentifier
        return vault.utf8.map { String(format: "%02x", $0) }.joined() + ":" + id.utf8.map { String(format: "%02x", $0) }.joined()
    }

    func isOfflineFailure(_ error: Error) -> Bool {
        if let error = error as? URLError { return [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut, .cannotFindHost, .dnsLookupFailed].contains(error.code) }
        if let error = error as? StorageError {
            switch error { case .networkError, .notConfigured: return true; case .serverError(let code, _): return code >= 500; default: return false }
        }
        if let error = error as? VFSError {
            switch error { case .networkError, .storageNotConfigured: return true; default: return false }
        }
        return (error as? NSFileProviderError)?.code == .serverUnreachable
    }

    func validateBaseVersion(_ version: NSFileProviderItemVersion, item: VirtualFileItem, preserving contents: URL? = nil) throws {
        let current = makeItem(vfsItem: item, isEncrypted: vfs.isEncrypted).itemVersion.contentVersion
        guard !version.contentVersion.isEmpty, version.contentVersion != NSFileProviderItemVersion.beforeFirstSyncComponent, version.contentVersion != current else { return }
        // Retain the user's conflicting bytes independently of the system-owned URL.
        if let contents {
            let directory = CloudDrivePaths.vaultDirectory(for: currentVaultIdentifier).appendingPathComponent("Conflicts", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let saved = directory.appendingPathComponent(UUID().uuidString + "_" + item.name)
            if copyfile(contents.path, saved.path, nil, copyfile_flags_t(COPYFILE_CLONE)) != 0 {
                try FileManager.default.copyItem(at: contents, to: saved)
            }
            var metadata = syncManager.getMetadata(fileId: item.id) ?? FileMetadata(fileId: item.id, name: item.name, parentId: item.parentId, isDirectory: item.isDirectory, syncStatus: .conflict, remotePath: item.remotePath)
            metadata.syncStatus = .conflict
            metadata.localPath = saved.path
            syncManager.updateMetadata(metadata)
        }
        throw NSFileProviderError(.cannotSynchronize)
    }
}
