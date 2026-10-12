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

    func isReadRevisionConflict(_ error: Error) -> Bool {
        if (error as? StorageError)?.isPreconditionFailure == true { return true }
        if case WebDAVError.serverError(let status) = error { return status == 412 }
        return false
    }

    func requestedETag(_ version: NSFileProviderItemVersion?, fileId: String? = nil, remoteETag: String? = nil) -> String? {
        guard let bytes = version?.contentVersion, let value = String(data: bytes, encoding: .utf8) else { return nil }
        if value.hasPrefix("etag-sha256:") {
            var candidates = [remoteETag]
            if let fileId, let metadata = try? syncManager.getMetadataPersistent(fileId: fileId) {
                candidates += [metadata.remoteETag, metadata.etag]
            }
            return candidates.compactMap { $0 }.first { ContentRevision.tokenForETag($0) == value }
        }
        guard value.hasPrefix("etag:") else { return nil }
        let tag = String(value.dropFirst(5))
        return tag.isEmpty ? nil : tag
    }

    func validateRequestedContentVersion(_ version: NSFileProviderItemVersion?, item: VirtualFileItem) throws {
        guard let version, !version.contentVersion.isEmpty,
              version.contentVersion != NSFileProviderItemVersion.beforeFirstSyncComponent else { return }
        _ = try syncManager.getMetadataPersistent(fileId: item.id)
        let current = makeItem(vfsItem: item, isEncrypted: vfs.isEncrypted).itemVersion.contentVersion
        guard version.contentVersion == current else { throw NSFileProviderError(.versionNoLongerAvailable) }
    }

    func validateBaseVersion(_ version: NSFileProviderItemVersion, item: VirtualFileItem, preserving contents: URL? = nil) throws {
        _ = try syncManager.getMetadataPersistent(fileId: item.id)
        let current = makeItem(vfsItem: item, isEncrypted: vfs.isEncrypted).itemVersion.contentVersion
        guard !version.contentVersion.isEmpty,
              version.contentVersion != NSFileProviderItemVersion.beforeFirstSyncComponent,
              version.contentVersion != current else { return }
        if let contents {
            // Saving a stale Finder edit cannot replace the newer revision.
            // Make the rejected content independently recoverable before failing.
            let backup = DeletedPayloadBackupStore(vaultId: currentVaultIdentifier)
            _ = try backup.preserve(source: contents, fileId: item.id, name: item.name, parentId: item.parentId, remotePath: item.remotePath, expectedETag: requestedETag(version, fileId: item.id))
        }
        signalEnumeratorDebounced(for: .workingSet)
        throw NSFileProviderError(.versionNoLongerAvailable)
    }
}
