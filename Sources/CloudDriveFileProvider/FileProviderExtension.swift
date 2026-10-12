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
class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderThumbnailing, NSFileProviderPartialContentFetching, NSFileProviderCustomAction {
    
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
    /// Ensures vault is fully unlocked or configured before proceeding with operations
    func ensureVaultUnlocked() async throws {
        // 1. If vault is configured and already in ready/unlocked state, fast return
        if let vault = vaultInfo {
            if vault.isEncrypted {
                if vfs.isEncrypted {
                    return
                }
            } else if vfs.isDirectMapping || vfs.activeProvider != nil {
                return
            }
        }
        
        // 2. If an unlock task is in progress, await it
        if let task = unlockTask {
            do {
                try await task.value
                if vaultInfo?.isEncrypted == true && !vfs.isEncrypted {
                    self.unlockTask = nil
                    throw VFSError.vaultLocked
                }
                return
            } catch {
                self.unlockTask = nil
                throw error
            }
        }
        
        // 3. Resolve domain configuration fresh
        let sharedDefaults = UserDefaults(suiteName: "group.net.aabg.CloudDrive")
        if sharedDefaults?.string(forKey: "lockedVaultId") == currentVaultIdentifier {
            throw VFSError.vaultLocked
        }
        
        let resolved = DomainConfiguration.resolve(domain: self.domain)
        guard let vault = resolved.vault else {
            throw VFSError.vaultNotFound("Vault configuration not found")
        }
        self.vaultInfo = vault
        self.webdavPasswordFromUserInfo = resolved.webdavPassword
        self.vaultPasswordFromUserInfo = resolved.vaultPassword
        self.bookmarkDataFromUserInfo = resolved.bookmarkData
        
        if vault.isEncrypted {
            guard let pwd = resolved.vaultPassword, !pwd.isEmpty else {
                throw VFSError.vaultLocked
            }
        }
        
        self.configureAndLoadVault(vault)
        if let task = self.unlockTask {
            do {
                try await task.value
            } catch {
                self.unlockTask = nil
                throw error
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
        
        setupNotificationObservers()

        logSuccess(.system, "✅ Extension initialized successfully")
    }
    
    private var cacheObserver: NSObjectProtocol?
    private var vaultLockedObserver: NSObjectProtocol?
    private var vaultUnlockedObserver: NSObjectProtocol?
    var materializedIds: Set<String> { stateStore.materializedIds() }
    var stateStore: FileProviderStateStore { FileProviderStateStore(vaultId: vaultInfo?.id ?? domain.identifier.rawValue) }

    private func setupNotificationObservers() {
        let center = DistributedNotificationCenter.default()
        cacheObserver = center.addObserver(forName: NSNotification.Name("net.aabg.CloudDrive.cacheChanged"), object: nil, queue: nil) { [weak self] note in
            self?.handleCacheChange(note)
        }
        vaultLockedObserver = center.addObserver(forName: NSNotification.Name("net.aabg.CloudDrive.vaultLocked"), object: nil, queue: nil) { [weak self] note in
            self?.handleVaultLocked(note)
        }
        vaultUnlockedObserver = center.addObserver(forName: NSNotification.Name("net.aabg.CloudDrive.vaultUnlocked"), object: nil, queue: nil) { [weak self] note in
            self?.handleVaultUnlocked(note)
        }
        
        let cfCenter = CFNotificationCenterGetDistributedCenter()
        CFNotificationCenterAddObserver(
            cfCenter,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let ext = Unmanaged<FileProviderExtension>.fromOpaque(observer).takeUnretainedValue()
                ext.handleVaultUnlockedSignal()
            },
            "net.aabg.CloudDrive.vaultUnlocked" as CFString,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            cfCenter,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let ext = Unmanaged<FileProviderExtension>.fromOpaque(observer).takeUnretainedValue()
                ext.handleVaultLockedSignal()
            },
            "net.aabg.CloudDrive.vaultLocked" as CFString,
            nil,
            .deliverImmediately
        )
    }

    func handleVaultLockedSignal() {
        let sharedDefaults = UserDefaults(suiteName: "group.net.aabg.CloudDrive")
        let lockedId = sharedDefaults?.string(forKey: "lockedVaultId")
        if let lockedId, !lockedId.isEmpty, lockedId != currentVaultIdentifier {
            return
        }
        logInfo(.system, "🔒 FileProviderExtension: Received vaultLocked signal for vault: \(currentVaultIdentifier)")
        
        self.syncManager.pauseSyncQueue()
        self.unlockTask = nil
        self.vaultPasswordFromUserInfo = nil
        self.vfs.lock()
        // Evict materialized files from macOS FileProvider domain so Finder marks them as dataless placeholders
        let manager = NSFileProviderManager(for: self.domain)
        for fileId in self.materializedIds {
            if syncManager.hasPendingOperation(fileId: fileId) || syncManager.getMetadata(fileId: fileId)?.syncStatus.protectsLocalChanges == true {
                continue
            }
            manager?.evictItem(identifier: NSFileProviderItemIdentifier(fileId)) { _ in }
        }
        // NOTE: We deliberately preserve self.cacheManager local storage!
        // Once unlocked, previously downloaded files can be used immediately without redownloading.
        self.signalEnumeratorDebounced(for: .rootContainer)
        self.signalEnumeratorDebounced(for: .workingSet)
    }

    func handleVaultUnlockedSignal() {
        let sharedDefaults = UserDefaults(suiteName: "group.net.aabg.CloudDrive")
        let unlockedId = sharedDefaults?.string(forKey: "unlockedVaultId")
        if let unlockedId, !unlockedId.isEmpty, unlockedId != currentVaultIdentifier {
            return
        }
        sharedDefaults?.removeObject(forKey: "lockedVaultId")
        logInfo(.system, "🔓 FileProviderExtension: Received vaultUnlocked signal for vault: \(currentVaultIdentifier)")
        
        self.unlockTask = nil
        let resolved = DomainConfiguration.resolve(domain: self.domain)
        if let vault = resolved.vault {
            self.vaultInfo = vault
            self.webdavPasswordFromUserInfo = resolved.webdavPassword
            self.vaultPasswordFromUserInfo = resolved.vaultPassword
            self.bookmarkDataFromUserInfo = resolved.bookmarkData
            self.configureAndLoadVault(vault)
        }
        self.signalEnumeratorDebounced(for: .rootContainer)
        self.signalEnumeratorDebounced(for: .workingSet)
    }

    func handleVaultLocked(_ note: Notification) {
        if let noteVaultId = note.userInfo?["vaultId"] as? String, noteVaultId != currentVaultIdentifier {
            return
        }
        handleVaultLockedSignal()
    }

    func handleVaultUnlocked(_ note: Notification) {
        if let noteVaultId = note.userInfo?["vaultId"] as? String, noteVaultId != currentVaultIdentifier {
            return
        }
        if let tokenStr = note.userInfo?["baiduToken"] as? String,
           let tokenData = tokenStr.data(using: .utf8),
           let payload = try? JSONDecoder().decode(BaiduPanTokenStore.TokenPayload.self, from: tokenData),
           !payload.accessToken.isEmpty {
            Logger.shared.info(.system, "🔑 [FileProviderExtension] Received baiduToken via DistributedNotification for vault \(currentVaultIdentifier), len: \(payload.accessToken.count)")
            BaiduPanTokenStore.setInMemoryToken(
                vaultID: currentVaultIdentifier,
                appID: payload.appID,
                clientID: payload.clientID,
                accessToken: payload.accessToken,
                refreshToken: payload.refreshToken,
                expiresAt: payload.expiresAt,
                generation: payload.generation,
                needsReauth: false
            )
            BaiduPanTokenStore.setInMemoryToken(
                vaultID: "default",
                appID: payload.appID,
                clientID: payload.clientID,
                accessToken: payload.accessToken,
                refreshToken: payload.refreshToken,
                expiresAt: payload.expiresAt,
                generation: payload.generation,
                needsReauth: false
            )
            try? BaiduPanTokenStore().saveAuthorized(
                vaultID: currentVaultIdentifier,
                appID: payload.appID,
                clientID: payload.clientID,
                accessToken: payload.accessToken,
                refreshToken: payload.refreshToken,
                expiresIn: Int(max(60, payload.expiresAt.timeIntervalSinceNow))
            )
            try? BaiduPanTokenStore().saveAuthorized(
                vaultID: "default",
                appID: payload.appID,
                clientID: payload.clientID,
                accessToken: payload.accessToken,
                refreshToken: payload.refreshToken,
                expiresIn: Int(max(60, payload.expiresAt.timeIntervalSinceNow))
            )
            _ = CredentialStore.shared.saveBaiduPanToken(data: tokenData, for: currentVaultIdentifier)
            _ = CredentialStore.shared.saveBaiduPanToken(data: tokenData, for: "default")
        }
        if let vp = note.userInfo?["vaultPassword"] as? String {
            self.vaultPasswordFromUserInfo = vp
            _ = CredentialStore.shared.saveVaultPassword(vp, for: currentVaultIdentifier)
        }
        if let sp = (note.userInfo?["storagePassword"] as? String) ?? (note.userInfo?["webdavPassword"] as? String) {
            self.webdavPasswordFromUserInfo = sp
            _ = CredentialStore.shared.saveStoragePassword(sp, for: currentVaultIdentifier)
        }
        handleVaultUnlockedSignal()
    }

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
            guard let self = self else { completionHandler(); return }
            if let ids = ids {
                try? self.stateStore.setMaterializedIds(ids)
            }
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
        if let vaultLockedObserver { DistributedNotificationCenter.default().removeObserver(vaultLockedObserver) }
        vaultLockedObserver = nil
        if let vaultUnlockedObserver { DistributedNotificationCenter.default().removeObserver(vaultUnlockedObserver) }
        vaultUnlockedObserver = nil
        
        let cfCenter = CFNotificationCenterGetDistributedCenter()
        CFNotificationCenterRemoveEveryObserver(cfCenter, Unmanaged.passUnretained(self).toOpaque())
        
        logSuccess(.system, "✅ FileProvider: Resource cleanup completed")
    }
    
}
