//
//  FileProviderExtension.swift
//  CloudDriveFileProvider
//
//  File Provider Extension Core Implementation
//

import FileProvider
import UniformTypeIdentifiers
import CloudDriveCore
import CloudDriveStorage


// Conforms to NSObject and protocol rather than subclassing
class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderThumbnailing {
    
    var vfs = VirtualFileSystem()
    var cacheManager: CacheManager { vfs.cacheManager }
    var webdavPasswordFromUserInfo: String?
    var vaultPasswordFromUserInfo: String?
    var bookmarkDataFromUserInfo: Data?

    let sync = FileProviderSync.shared
    var syncManager: SyncManager { vfs.syncManager }
    let operationManager = FileOperationManager.shared
    
    func signalEnumeratorDebounced(for identifier: NSFileProviderItemIdentifier) {
        Task {
            await EnumeratorSignaler.shared.signal(domain: self.domain, for: identifier)
        }
    }
    let domain: NSFileProviderDomain
    var vaultInfo: VaultInfo?
    var unlockTask: Task<Void, Error>?
    
    public var currentVaultIdentifier: String {
        if let id = vaultInfo?.id, !id.isEmpty { return id }
        let raw = domain.identifier.rawValue
        return raw.hasPrefix("vault-") ? String(raw.dropFirst(6)) : raw
    }
    
    /// Ensures vault is fully unlocked or configured before proceeding with operations
    func ensureVaultUnlocked() async throws {
        if let task = unlockTask {
            try await task.value
        } else if vaultInfo != nil {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let task = unlockTask {
                try await task.value
            }
        } else {
            // Attempt to resolve domain configuration again if delayed
            let resolved = DomainConfiguration.resolve(domain: self.domain)
            if let vault = resolved.vault {
                self.vaultInfo = vault
                self.webdavPasswordFromUserInfo = resolved.webdavPassword
                self.vaultPasswordFromUserInfo = resolved.vaultPassword
                self.bookmarkDataFromUserInfo = resolved.bookmarkData
                self.configureAndLoadVault(vault)
                if let task = self.unlockTask {
                    try await task.value
                }
            } else {
                throw VFSError.vaultNotFound("Vault configuration not found")
            }
        }
    }
    
    required init(domain: NSFileProviderDomain) {
        NSLog("🔧 FileProvider: Initializing extension for domain: \(domain.identifier.rawValue)")
        logInfo(.system, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        logInfo(.system, "FileProvider Extension initializing")
        logInfo(.system, "Domain: \(domain.identifier.rawValue)")
        logInfo(.system, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        self.domain = domain
        super.init()
        
        let resolved = DomainConfiguration.resolve(domain: domain)
        if let vault = resolved.vault {
            self.vaultInfo = vault
            self.webdavPasswordFromUserInfo = resolved.webdavPassword
            self.vaultPasswordFromUserInfo = resolved.vaultPassword
            self.bookmarkDataFromUserInfo = resolved.bookmarkData
            configureAndLoadVault(vault)
        } else {
            logError(.system, "❌ Failed to get vault config (Domain: \(domain.identifier.rawValue))")
        }
        
        let center = DistributedNotificationCenter.default()
        cacheObserver = center.addObserver(forName: NSNotification.Name("net.aabg.CloudDrive.cacheChanged"), object: nil, queue: nil) { [weak self] note in
            self?.handleCacheChange(note)
        }

        logSuccess(.system, "✅ Extension initialized successfully")
    }
    
    private var cacheObserver: NSObjectProtocol?
    var materializedIds: Set<String> { stateStore.materializedIds() }
    var stateStore: FileProviderStateStore { FileProviderStateStore(vaultId: vaultInfo?.id ?? domain.identifier.rawValue) }

    func handleCacheChange(_ note: Notification) {
        guard note.userInfo?["vaultId"] as? String == vaultInfo?.id else { return }
        let kind = note.userInfo?["kind"] as? String
        let manager = NSFileProviderManager(for: domain)
        if let fileId = note.userInfo?["fileId"] as? String {
            if kind == "eviction" { manager?.evictItem(identifier: NSFileProviderItemIdentifier(fileId)) { _ in } }
            if let item = try? vfs.getItem(id: fileId) {
                signalEnumeratorDebounced(for: item.parentId == "ROOT" ? .rootContainer : NSFileProviderItemIdentifier(item.parentId))
            }
        } else if kind == "eviction" {
            for id in materializedIds where !cacheManager.isCached(fileId: id) && syncManager.getMetadata(fileId: id)?.syncStatus == .cloudOnly {
                manager?.evictItem(identifier: NSFileProviderItemIdentifier(id)) { _ in }
            }
        }
        signalEnumeratorDebounced(for: .workingSet)
    }

    func makeItem(vfsItem: VirtualFileItem, isEncrypted: Bool = false) -> FileProviderItem {
        FileProviderItem(vfsItem: vfsItem, isEncrypted: isEncrypted, cacheManager: cacheManager, syncManager: syncManager)
    }
    func makeItem(identifier: NSFileProviderItemIdentifier, parentIdentifier: NSFileProviderItemIdentifier,
                  filename: String, contentType: UTType, capabilities: NSFileProviderItemCapabilities,
                  documentSize: Int64? = nil, contentModificationDate: Date? = nil, creationDate: Date? = nil,
                  isEncrypted: Bool = false) -> FileProviderItem {
        FileProviderItem(identifier: identifier, parentIdentifier: parentIdentifier, filename: filename,
                         contentType: contentType, capabilities: capabilities, documentSize: documentSize,
                         contentModificationDate: contentModificationDate, creationDate: creationDate,
                         isEncrypted: isEncrypted, cacheManager: cacheManager, syncManager: syncManager)
    }

    func materializedItemsDidChange(completionHandler: @escaping () -> Void) {
        guard let manager = NSFileProviderManager(for: domain) else { completionHandler(); return }
        let enumerator = manager.enumeratorForMaterializedItems()
        let observer = MaterializedSetObserver(enumerator: enumerator) { [weak self] ids in
            if let ids { try? self?.stateStore.setMaterializedIds(ids) }
            completionHandler()
        }
        observer.start()
    }

    // MARK: - NSFileProviderReplicatedExtension Required Methods
    func invalidate() {
        logInfo(.system, "🔄 FileProvider: Extension invalidated")
        
        // Clean up resources to prevent reuse after failure
        self.vaultInfo = nil
        
        // Reset current instance VFS state
        self.vfs.lock()
        
        if let cacheObserver { DistributedNotificationCenter.default().removeObserver(cacheObserver) }
        cacheObserver = nil
        
        logSuccess(.system, "✅ FileProvider: Resource cleanup completed")
    }
    
}
