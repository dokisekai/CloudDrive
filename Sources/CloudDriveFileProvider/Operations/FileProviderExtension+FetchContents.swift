import Foundation
import FileProvider
import UniformTypeIdentifiers
import CloudDriveCore

extension FileProviderExtension {
    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let task = Task { [weak self] in
            guard let self else { completionHandler(nil, nil, NSFileProviderError(.noSuchItem)); return }
            let id = itemIdentifier.rawValue
            do {
                try Task.checkCancellation()
                try await ensureVaultUnlocked()
                cacheManager.beginAccess(fileId: id)
                defer { cacheManager.endAccess(fileId: id) }
                var item = try findItem(identifier: id)
                let metadata = syncManager.getMetadata(fileId: id)
                let dirty = metadata.map { $0.syncStatus != .synced && $0.syncStatus != .cloudOnly && $0.syncStatus != .downloading && $0.syncStatus != .partialDownload } ?? false
                if let requestedVersion, requestedVersion.contentVersion != NSFileProviderItemVersion.beforeFirstSyncComponent,
                   requestedVersion.contentVersion != makeItem(vfsItem: item, isEncrypted: vfs.isEncrypted).itemVersion.contentVersion {
                    throw NSFileProviderError(.versionNoLongerAvailable)
                }
                let cacheURL = cacheManager.localPath(for: id)
                var valid = cacheManager.isCached(fileId: id)
                if valid && !dirty, let cached = cacheManager.getCacheMetadata(fileId: id) {
                    if let remoteRevision = item.etag, let baselineRevision = metadata?.etag { valid = remoteRevision == baselineRevision }
                    else { valid = item.modifiedAt <= cached.downloadedAt.addingTimeInterval(1) && item.size == cached.size }
                }
                if !valid, dirty, let path = metadata?.localPath, FileManager.default.fileExists(atPath: path) {
                    try cacheManager.cacheFile(fileId: id, from: URL(fileURLWithPath: path))
                    valid = true
                }
                if valid {
                    cacheManager.updateLastAccessed(fileId: id)
                    // Reading locally staged edits must not confirm their upload.
                    let handoff = try ContentHandoff.create(from: cacheURL, domain: domain)
                    try Task.checkCancellation()
                    progress.completedUnitCount = 100
                    completionHandler(handoff, makeItem(vfsItem: item, isEncrypted: vfs.isEncrypted), nil)
                    return
                }
                var downloading = metadata ?? FileMetadata(fileId: id, name: item.name, parentId: item.parentId, isDirectory: false, syncStatus: .cloudOnly, remotePath: item.remotePath, size: item.size)
                downloading.syncStatus = .downloading
                downloading.downloadProgress = 0
                syncManager.updateMetadata(downloading)
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: tempURL) }
                try await vfs.downloadFile(fileId: id, to: tempURL) { fraction in
                    progress.completedUnitCount = Int64(fraction * 100)
                    if var update = self.syncManager.getMetadata(fileId: id), update.syncStatus == .downloading {
                        update.downloadProgress = fraction
                        self.syncManager.updateMetadata(update)
                    }
                }
                try Task.checkCancellation()
                if let latest = syncManager.getMetadata(fileId: id), latest.syncStatus != .downloading && latest.syncStatus != .synced && latest.syncStatus != .cloudOnly {
                    throw CocoaError(.fileWriteUnknown)
                }
                try cacheManager.cacheFile(fileId: id, from: tempURL)
                // Providers record the actual GET response ETag; never replace it with listing metadata.
                var downloaded = syncManager.getMetadata(fileId: id) ?? downloading
                downloaded.syncStatus = .synced
                downloaded.localPath = cacheURL.path
                downloaded.downloadProgress = 1
                downloaded.lastSyncTime = Date()
                downloaded.localModifiedAt = item.modifiedAt
                downloaded.remoteModifiedAt = item.modifiedAt
                syncManager.updateMetadata(downloaded)
                item = (try? findItem(identifier: id)) ?? item
                let handoff = try ContentHandoff.create(from: cacheURL, domain: domain)
                progress.completedUnitCount = 100
                completionHandler(handoff, makeItem(vfsItem: item, isEncrypted: vfs.isEncrypted), nil)
            } catch {
                if var metadata = syncManager.getMetadata(fileId: id), metadata.syncStatus == .downloading {
                    metadata.syncStatus = error is CancellationError ? .cloudOnly : .error
                    syncManager.updateMetadata(metadata)
                }
                let mapped: Error = error is CancellationError ? CocoaError(.userCancelled) : (error as? NSFileProviderError ?? (error as? VFSError).map { mapToFileProviderError($0) } ?? NSFileProviderError(.serverUnreachable))
                completionHandler(nil, nil, mapped)
            }
        }
        progress.cancellationHandler = { task.cancel() }
    return progress
    }
}
