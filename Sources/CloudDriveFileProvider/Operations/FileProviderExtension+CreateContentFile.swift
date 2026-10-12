import Foundation
import FileProvider
import UniformTypeIdentifiers
import CloudDriveCore

extension FileProviderExtension {
    func handleCreateContentFile(itemTemplate: NSFileProviderItem, actualParentId: String, url: URL, progress: Progress, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) async throws {
        let staged = try PendingContentStager(vaultId: currentVaultIdentifier).stage(url, filename: itemTemplate.filename)
        let destination = try createdFileDestination(itemTemplate: itemTemplate, parentId: actualParentId)
        let incomingId = "copy-input-" + UUID().uuidString
        cacheManager.beginAccess(fileId: incomingId)
        defer {
            cacheManager.endAccess(fileId: incomingId)
            try? cacheManager.removeCachedFile(fileId: incomingId)
        }
        var preparedCacheId: String?
        if !destination.excluded {
            do {
                try cacheManager.cacheFile(fileId: incomingId, from: staged)
                preparedCacheId = incomingId
            } catch { logWarning(.cache, "Identical-copy lookup unavailable: \(error.localizedDescription)") }
        }
        var copiedItem: FileProviderItem?
        if preparedCacheId != nil, let source = cacheManager.matchingConfirmedSource(for: incomingId) {
            do {
                let copied = try await vfs.copyItem(itemId: source.fileId, newParentId: actualParentId,
                    newName: itemTemplate.filename, cachedContentOverride: incomingId, expectedSourceETag: source.etag)
                copiedItem = makeItem(vfsItem: copied, isEncrypted: vfs.isEncrypted)
                try? FileManager.default.removeItem(at: staged)
            } catch let error as StorageError {
                // Only definite precondition/unsupported failures may switch to create-if-absent.
                if !error.isPreconditionFailure {
                    guard case .notSupported = error else { throw error }
                }
            }
        }
        let item: FileProviderItem
        if let copiedItem { item = copiedItem }
        else { item = try acceptCreatedFile(itemTemplate: itemTemplate, parentId: actualParentId, staged: staged, preparedCacheId: preparedCacheId) }
        progress.completedUnitCount = 100
        signalEnumeratorDebounced(for: itemTemplate.parentItemIdentifier)
        signalEnumeratorDebounced(for: .workingSet)
        completionHandler(item, [], false, nil)
    }
}
