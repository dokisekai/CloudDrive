import Foundation
import FileProvider
import UniformTypeIdentifiers
import CloudDriveCore
import CloudDriveContracts

extension FileProviderExtension {
    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let task = Task { [weak self] in
            guard let self else { completionHandler(nil, nil, NSFileProviderError(.noSuchItem)); return }
            let id = itemIdentifier.rawValue
            var initialMetadata: FileMetadata?
            var effectiveId = id
            do {
                try Task.checkCancellation()
                try await ensureVaultUnlocked()
                var item = try findItem(identifier: id)
                effectiveId = item.id
                cacheManager.beginAccess(fileId: effectiveId)
                defer { cacheManager.endAccess(fileId: effectiveId) }
                let cacheURL = cacheManager.localPath(for: effectiveId)
                func completionItem(_ value: VirtualFileItem) -> FileProviderItem {
                    if effectiveId == id { return self.makeItem(vfsItem: value, isEncrypted: self.vfs.isEncrypted) }
                    return FileProviderItem(identifier: itemIdentifier, parentIdentifier: (value.parentId == "ROOT" || value.parentId == "/") ? .rootContainer : NSFileProviderItemIdentifier(value.parentId), filename: value.name, contentType: value.isDirectory ? .folder : .data, capabilities: [.allowsReading, .allowsWriting, .allowsDeleting, .allowsTrashing, .allowsRenaming, .allowsReparenting], documentSize: value.size, contentModificationDate: value.modifiedAt, creationDate: value.modifiedAt, isEncrypted: self.vfs.isEncrypted, remoteETag: value.etag, cacheManager: self.cacheManager, syncManager: self.syncManager)
                }
                var deliveredItem: FileProviderItem?
                let cachedHandoff: URL? = try syncManager.withJournalCommit {
                    try validateRequestedContentVersion(requestedVersion, item: item)
                    let metadata = try syncManager.getMetadataPersistent(fileId: effectiveId)
                    initialMetadata = metadata
                    let pending = try syncManager.queue.itemsForFilePersistent(fileId: effectiveId)
                    let protectsEdit = metadata?.syncStatus.protectsLocalChanges == true || !pending.isEmpty
                    let cacheMatchesRevision = metadata?.etag == item.etag
                    var source: URL?
                    if let path = metadata?.localPath, FileManager.default.fileExists(atPath: path), protectsEdit || cacheMatchesRevision {
                        source = URL(fileURLWithPath: path)
                    } else if cacheManager.isCached(fileId: effectiveId), protectsEdit || cacheMatchesRevision {
                        source = cacheURL
                    }
                    if let source {
                        // Local availability does not confirm that an edit was uploaded.
                        cacheManager.updateLastAccessed(fileId: effectiveId)
                        let snapshot = try ContentHandoff.create(from: source, domain: domain)
                        deliveredItem = completionItem(item)
                        return snapshot
                    }
                    guard !protectsEdit else { throw NSFileProviderError(.serverUnreachable) }
                    var downloading = metadata ?? FileMetadata(fileId: effectiveId, name: item.name, parentId: item.parentId, isDirectory: false, syncStatus: .cloudOnly, remotePath: item.remotePath, size: item.size)
                    downloading.syncStatus = .downloading
                    downloading.downloadProgress = 0
                    try syncManager.updateMetadataPersistent(downloading)
                    return nil
                }
                if let cachedHandoff {
                    progress.completedUnitCount = 100
                    completionHandler(cachedHandoff, deliveredItem, nil)
                    return
                }
                guard let remotePath = item.remotePath ?? initialMetadata?.remotePath else { throw NSFileProviderError(.noSuchItem) }
                let expected = requestedETag(requestedVersion, fileId: effectiveId, remoteETag: item.etag) ?? item.etag
                if let requestedVersion, !requestedVersion.contentVersion.isEmpty,
                   requestedVersion.contentVersion != NSFileProviderItemVersion.beforeFirstSyncComponent, expected == nil {
                    throw NSFileProviderError(.versionNoLongerAvailable)
                }
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: tempURL) }
                // Revision-aware download has no side effects on sync metadata.
                let deliveredETag = try await vfs.downloadConflictContent(fileId: effectiveId, remotePath: remotePath, to: tempURL, expectedETag: expected)
                try Task.checkCancellation()
                let handoff = try syncManager.withJournalCommit {
                    let current = try syncManager.getMetadataPersistent(fileId: effectiveId)
                    guard current?.syncStatus == .downloading,
                          current?.localPath == initialMetadata?.localPath,
                          current?.localModifiedAt == initialMetadata?.localModifiedAt,
                          (try syncManager.queue.itemsForFilePersistent(fileId: effectiveId)).isEmpty else {
                        throw NSFileProviderError(.versionNoLongerAvailable)
                    }
                    if let expected, deliveredETag != expected { throw NSFileProviderError(.versionNoLongerAvailable) }
                    try cacheManager.cacheFile(fileId: effectiveId, from: tempURL, confirmedETag: deliveredETag)
                    var downloaded = current ?? FileMetadata(fileId: effectiveId, name: item.name, parentId: item.parentId, isDirectory: false, syncStatus: .synced, remotePath: remotePath, size: item.size)
                    downloaded.syncStatus = .synced
                    downloaded.etag = deliveredETag
                    downloaded.localPath = cacheURL.path
                    downloaded.downloadProgress = 1
                    downloaded.lastSyncTime = Date()
                    downloaded.remoteModifiedAt = item.modifiedAt
                    try syncManager.updateMetadataPersistent(downloaded)
                    let snapshot = try ContentHandoff.create(from: cacheURL, domain: domain)
                    item.etag = deliveredETag
                    deliveredItem = completionItem(item)
                    return snapshot
                }
                item.etag = deliveredETag
                progress.completedUnitCount = 100
                completionHandler(handoff, deliveredItem, nil)
            } catch {
                try? syncManager.withJournalCommit {
                    if var current = try syncManager.getMetadataPersistent(fileId: effectiveId), current.syncStatus == .downloading,
                       current.localPath == initialMetadata?.localPath, current.localModifiedAt == initialMetadata?.localModifiedAt,
                       (try syncManager.queue.itemsForFilePersistent(fileId: effectiveId)).isEmpty {
                        current.syncStatus = initialMetadata?.syncStatus ?? .cloudOnly
                        current.downloadProgress = initialMetadata?.downloadProgress ?? 0
                        try syncManager.updateMetadataPersistent(current)
                    }
                }
                let mapped: Error = isReadRevisionConflict(error) ? NSFileProviderError(.versionNoLongerAvailable) : error is CancellationError ? CocoaError(.userCancelled) : (error as? NSFileProviderError ?? mapToFileProviderError(error))
                completionHandler(nil, nil, mapped)
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }
}
