import Foundation
import FileProvider
import CloudDriveCore
import CloudDriveRecovery

final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let enumeratedItemIdentifier: NSFileProviderItemIdentifier
    private let vfs: VirtualFileSystem
    private weak var extensionRef: FileProviderExtension?
    private var activeTask: Task<Void, Never>?
    private var vaultId: String { vfs.vaultId ?? extensionRef?.currentVaultIdentifier ?? "unconfigured" }
    private var state: FileProviderStateStore { FileProviderStateStore(vaultId: vaultId) }

    init(enumeratedItemIdentifier: NSFileProviderItemIdentifier, vfs: VirtualFileSystem, extensionRef: FileProviderExtension? = nil) {
        self.enumeratedItemIdentifier = enumeratedItemIdentifier
        self.vfs = vfs
        self.extensionRef = extensionRef
        super.init()
    }
    func invalidate() { activeTask?.cancel(); activeTask = nil }

    private func loadItems() async throws -> [FileProviderItem] {
        try Task.checkCancellation()
        if let ext = extensionRef {
            do {
                try await ext.ensureVaultUnlocked()
            } catch VFSError.vaultLocked {
                let center = DistributedNotificationCenter.default()
                center.postNotificationName(
                    NSNotification.Name("net.aabg.CloudDrive.requestUnlock"),
                    object: nil,
                    userInfo: ["vaultId": vaultId],
                    deliverImmediately: true
                )
                throw VFSError.vaultLocked
            }
        }
        let manager = vfs.syncManager
        var items: [String: VirtualFileItem] = [:]
        if enumeratedItemIdentifier == .workingSet {
            let root = (try? vfs.listDirectory(directoryId: "ROOT")) ?? []
            for item in root { items[item.id] = item }

            // All records here are already scoped to this vault.
            for metadata in manager.getAllMetadata() where metadata.syncStatus != .pendingDelete {
                if let item = try? vfs.getItem(id: metadata.fileId) { items[item.id] = item }
                else if metadata.syncStatus.needsSync || metadata.syncStatus == .localOnly {
                    items[metadata.fileId] = VirtualFileItem(id: metadata.fileId, name: metadata.name, isDirectory: metadata.isDirectory, size: metadata.size, modifiedAt: metadata.localModifiedAt ?? .distantPast, parentId: metadata.parentId, syncStatus: metadata.syncStatus, localPath: metadata.localPath, remotePath: metadata.remotePath, etag: metadata.etag)
                }
            }
            for id in vfs.cacheManager.getAllCachedFileIds() + Array(state.materializedIds()) {
                if let item = try? vfs.getItem(id: id) { items[id] = item }
            }
            // Refresh materialized directories from local database cache (background refreshed if stale)
            for id in state.materializedIds() {
                guard let item = try? vfs.getItem(id: id), item.isDirectory else { continue }
                if let children = try? vfs.listDirectory(directoryId: id) {
                    for child in children { items[child.id] = child }
                }
            }
        } else if enumeratedItemIdentifier == .trashContainer {
            // Trash container is empty or managed locally; return empty list immediately to satisfy Finder
            return []
        } else {
            let directory = enumeratedItemIdentifier == .rootContainer ? "ROOT" : enumeratedItemIdentifier.rawValue
            let children: [VirtualFileItem]
            do {
                children = try await vfs.listDirectoryFromWebDAVAsync(directoryId: directory)
            } catch VFSError.vaultLocked {
                throw VFSError.vaultLocked
            } catch VFSError.invalidPassword {
                throw VFSError.invalidPassword
            } catch {
                try Task.checkCancellation()
                children = try vfs.listDirectory(directoryId: directory)
            }
            for child in children { items[child.id] = child }
            // Offline creates can be absent from a successful remote list. Keep them until committed.
            for metadata in manager.getAllMetadata() where metadata.parentId == directory && metadata.syncStatus != .pendingDelete && (metadata.syncStatus.needsSync || metadata.syncStatus == .localOnly || metadata.syncStatus.protectsLocalChanges) {
                if let child = try? vfs.getItem(id: metadata.fileId) {
                    items[child.id] = child
                } else {
                    items[metadata.fileId] = VirtualFileItem(
                        id: metadata.fileId,
                        name: metadata.name,
                        isDirectory: metadata.isDirectory,
                        size: metadata.size,
                        modifiedAt: metadata.localModifiedAt ?? Date(),
                        parentId: metadata.parentId,
                        syncStatus: metadata.syncStatus,
                        localPath: metadata.localPath,
                        remotePath: metadata.remotePath,
                        etag: metadata.etag
                    )
                }
            }
        }
        return items.values.filter { item in
            let isSystemJunk = item.name == ".DS_Store" || item.name.hasPrefix("._") || item.name == "Thumbs.db" || item.name == "desktop.ini" || item.name == ".thumbnails.catalog"
            if isSystemJunk {
                return false
            }
            return manager.getMetadata(fileId: item.id)?.syncStatus != .pendingDelete
        }.sorted { $0.id < $1.id }.map { item in
            var vfsItem = item
            let checkPath = vfsItem.remotePath ?? vfsItem.name
            let isIgnored = IgnoreRuleEngine.shared.shouldIgnore(path: checkPath, name: vfsItem.name, isDirectory: vfsItem.isDirectory, vaultId: vaultId)
            let isUserExcluded = IgnoreRuleEngine.shared.isUserExcluded(vaultId: vaultId, path: vfsItem.name) ||
                                 IgnoreRuleEngine.shared.isUserExcluded(vaultId: vaultId, path: checkPath)
            if (isIgnored || isUserExcluded || vfsItem.name.hasSuffix(".nosync")) && vfsItem.syncStatus != .localOnly {
                vfsItem.syncStatus = .localOnly
            }
            return FileProviderItem(vfsItem: vfsItem, isEncrypted: vfs.isEncrypted, cacheManager: vfs.cacheManager, syncManager: manager)
        }
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        activeTask = Task {
            do {
                let items = try await loadItems()
                try Task.checkCancellation()
                try state.record(container: enumeratedItemIdentifier.rawValue, items: items)
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                let mappedError: Error = error is CancellationError ? (CocoaError(.userCancelled) as Error) : (mapToFileProviderError(error) as Error)
                observer.finishEnumeratingWithError(mappedError)
            }
        }
    }
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        activeTask = Task {
            do {
                if enumeratedItemIdentifier == .trashContainer {
                    observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                    return
                }
                let items = try await loadItems()
                try Task.checkCancellation()
                let changes = try state.changes(container: enumeratedItemIdentifier.rawValue, from: anchor, items: items)
                if !changes.updated.isEmpty { observer.didUpdate(changes.updated) }
                if !changes.deleted.isEmpty { observer.didDeleteItems(withIdentifiers: changes.deleted) }
                observer.finishEnumeratingChanges(upTo: changes.anchor, moreComing: false)
            } catch {
                let mappedError: Error = error is CancellationError ? (CocoaError(.userCancelled) as Error) : (mapToFileProviderError(error) as Error)
                observer.finishEnumeratingWithError(mappedError)
            }
        }
    }
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(state.currentAnchor(container: enumeratedItemIdentifier.rawValue))
    }
}
