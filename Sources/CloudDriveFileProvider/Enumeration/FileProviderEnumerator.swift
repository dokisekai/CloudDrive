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
        if let ext = extensionRef { try await ext.ensureVaultUnlocked() }
        let manager = vfs.syncManager
        var items: [String: VirtualFileItem] = [:]
        if enumeratedItemIdentifier == .workingSet {
            let root = (try? vfs.listDirectory(directoryId: "ROOT")) ?? []
            for item in root { items[item.id] = item }
            if RecycleBinConfig.isEnabled(for: vaultId), let bin = vfs.getRecycleBinDirectory() {
                items[bin.id] = bin
            }
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
            // Refresh materialized directories, including removals that happened while Finder was closed.
            for id in state.materializedIds() {
                guard let item = try? vfs.getItem(id: id), item.isDirectory else { continue }
                if let children = try? await vfs.listDirectoryFromWebDAVAsync(directoryId: id) {
                    for child in children { items[child.id] = child }
                }
            }
        } else if enumeratedItemIdentifier == .trashContainer {
            // Trash container is empty or managed locally; return empty list immediately to satisfy Finder
            return []
        } else {
            let directory = enumeratedItemIdentifier == .rootContainer ? "ROOT" : enumeratedItemIdentifier.rawValue
            let children: [VirtualFileItem]
            do { children = try await vfs.listDirectoryFromWebDAVAsync(directoryId: directory) }
            catch { try Task.checkCancellation(); children = try vfs.listDirectory(directoryId: directory) }
            for child in children { items[child.id] = child }
            // Offline creates can be absent from a successful remote list. Keep them until committed.
            for metadata in manager.getAllMetadata() where metadata.parentId == directory && metadata.syncStatus != .pendingDelete && (metadata.syncStatus.needsSync || metadata.syncStatus == .localOnly) {
                if let child = try? vfs.getItem(id: metadata.fileId) { items[child.id] = child }
            }
            if directory == "ROOT" {
                if RecycleBinConfig.isEnabled(for: vaultId) {
                    if let bin = try? await vfs.getOrCreateRecycleBinDirectory() {
                        items[bin.id] = bin
                    }
                } else if let bin = vfs.getRecycleBinDirectory() {
                    items.removeValue(forKey: bin.id)
                }
            }
        }
        let isBinEnabled = RecycleBinConfig.isEnabled(for: vaultId)
        return items.values.filter { item in
            manager.getMetadata(fileId: item.id)?.syncStatus != .pendingDelete &&
            !IgnoreRuleEngine.shared.shouldIgnore(path: item.remotePath ?? item.name, name: item.name, isDirectory: item.isDirectory, vaultId: vaultId) &&
            (isBinEnabled || !vfs.isRecycleBinDirectory(id: item.id))
        }.sorted { $0.id < $1.id }.map {
            FileProviderItem(vfsItem: $0, isEncrypted: vfs.isEncrypted, cacheManager: vfs.cacheManager, syncManager: manager)
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
