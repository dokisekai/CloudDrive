import SwiftUI
import CloudDriveCore
import CloudDriveStorage
import FileProvider
import Network

extension AppState {
    func unlockVault(vaultId: String, password: String) async throws {
        guard let vault = vaults.first(where: { $0.id == vaultId }) else {
            throw NSError(domain: "CloudDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: L("err_vault_not_found")])
        }
        
        guard vault.isStorageEnabled else {
            throw StorageError.notSupported("Only WebDAV is enabled")
        }
        vfs.currentVaultId = vaultId
        print("🔓 AppState: Mounting vault: \(vault.name)")
        
        // 配置存储
        if let config = vault.storageConfig {
            if case .baidupan(let panConfig) = config {
                if !panConfig.refreshToken.isEmpty {
                    try? BaiduPanTokenStore().bootstrap(
                        vaultID: vaultId,
                        appID: panConfig.appID,
                        clientID: panConfig.appKey,
                        refreshToken: panConfig.refreshToken
                    )
                    try? BaiduPanTokenStore().bootstrap(
                        vaultID: "default",
                        appID: panConfig.appID,
                        clientID: panConfig.appKey,
                        refreshToken: panConfig.refreshToken
                    )
                }
                BaiduPanTokenStore().cloneCredentials(from: "default", to: vaultId)
            }
            let storagePassword = vault.isEncrypted ? (getWebDAVPassword(for: vaultId) ?? "") : password
            let effectiveConfig = (config.secret ?? "").isEmpty && !storagePassword.isEmpty ? config.replacingSecret(storagePassword) : config
            print("⚙️ AppState: Configuring storage for vault [\(effectiveConfig.type.displayName)]: \(effectiveConfig.summaryDescription)")
            vfs.configureStorage(configuration: effectiveConfig)
        } else if let webdavURL = vault.webdavURL,
           let webdavUsername = vault.webdavUsername,
           let url = URL(string: webdavURL) {
            let webdavPassword = vault.isEncrypted ? (getWebDAVPassword(for: vaultId) ?? password) : password
            vfs.configureWebDAV(baseURL: url, username: webdavUsername, password: webdavPassword)
            
            // 配置 SyncManager
            print("✅ AppState: Storage configured")
        }
        
        let effectiveStoragePath = vault.storagePath
        
        if vault.isEncrypted {
            try await vfs.unlockVault(password: password, storagePath: effectiveStoragePath, vaultId: vaultId)
            saveVaultPassword(password, for: vaultId)
        } else if vault.storagePath == "/" {
            try await vfs.remountDirectMappingVault(vaultId: vaultId, storagePath: vault.storagePath)
            saveWebDAVPassword(password, for: vaultId)
        } else {
            try await vfs.mountVaultWithoutEncryption(storagePath: vault.storagePath, vaultId: vaultId)
            saveWebDAVPassword(password, for: vaultId)
        }
        
        currentVault = vault
        isVaultUnlocked = true
        saveVaultConfigToSharedFile(vault)
        saveCredentialsToAppGroup(
            vaultId: vault.id,
            webdavPassword: vault.webdavUsername != nil ? getWebDAVPassword(for: vault.id) : nil,
            vaultPassword: vault.isEncrypted ? getVaultPassword(for: vault.id) : nil
        )
        
        // 更新挂载与解锁状态
        if let index = vaults.firstIndex(where: { $0.id == vaultId }) {
            // 创建新的 VaultInfo 实例，触发 SwiftUI 更新
            var updatedVault = vaults[index]
            updatedVault.isMounted = true
            updatedVault.isUnlocked = true
            updatedVault.isAutoMount = true
            vaults[index] = updatedVault
            saveVaults()
        }
        
        // 注册 FileProvider Domain 并刷新
        do {
            try await registerFileProviderDomain(for: vault)
        } catch {
            NSLog("⚠️ AppState: Domain registration failed during unlock: %@", error as NSError)
        }
        
        // 恢复并重跑同步队列，重置在途与鉴权失败任务
        SyncManager.forVault(vaultId).recoverQueueOnUnlock()
        
        let sharedDefaults = UserDefaults(suiteName: "group.net.aabg.CloudDrive")
        sharedDefaults?.removeObject(forKey: "lockedVaultId")
        sharedDefaults?.set(vaultId, forKey: "unlockedVaultId")
        sharedDefaults?.synchronize()

        // 广播保险库解锁通知
        FileProviderSync.shared.notifyVaultUnlocked(vaultId: vaultId)
        var unlockUserInfo: [AnyHashable: Any] = ["vaultId": vaultId]
        if let tokenStr = getBaiduTokenPayloadString(for: vaultId) {
            unlockUserInfo["baiduToken"] = tokenStr
        }
        if vault.isEncrypted {
            unlockUserInfo["vaultPassword"] = password
        }
        let sp = vault.isEncrypted ? getWebDAVPassword(for: vaultId) : password
        if let sp = sp, !sp.isEmpty {
            unlockUserInfo["storagePassword"] = sp
            unlockUserInfo["webdavPassword"] = sp
        }
        let center = DistributedNotificationCenter.default()
        center.postNotificationName(
            NSNotification.Name("net.aabg.CloudDrive.vaultUnlocked"),
            object: nil,
            userInfo: unlockUserInfo,
            deliverImmediately: true
        )
        
        Task {
            await syncFilesToFileProvider(vaultId: vaultId)
        }
        
        postSystemNotification(title: "CloudDrive", body: "保险库「\(vault.name)」已成功解锁")
        print("✅ AppState: Vault unlocked successfully")
    }

    func lockVault(_ vault: VaultInfo) {
        print("🔒 AppState: Locking vault: \(vault.name) (retaining mount)")
        
        // 1. 暂停传输队列
        SyncManager.forVault(vault.id).pauseSyncQueue()
        
        // 2. 保持 isMounted = true，仅将 isUnlocked 置为 false
        if let index = vaults.firstIndex(where: { $0.id == vault.id }) {
            var updatedVault = vaults[index]
            updatedVault.isUnlocked = false
            vaults[index] = updatedVault
            saveVaults()
        }
        
        if currentVault?.id == vault.id {
            vfs.lock()
            isVaultUnlocked = false
        }
        
        let sharedDefaults = UserDefaults(suiteName: "group.net.aabg.CloudDrive")
        sharedDefaults?.set(vault.id, forKey: "lockedVaultId")
        sharedDefaults?.removeObject(forKey: "unlockedVaultId")
        sharedDefaults?.synchronize()
        
        FileProviderSync.shared.notifyVaultLocked(vaultId: vault.id)
        let center = DistributedNotificationCenter.default()
        center.postNotificationName(
            NSNotification.Name("net.aabg.CloudDrive.vaultLocked"),
            object: nil,
            userInfo: ["vaultId": vault.id],
            deliverImmediately: true
        )
    }

    func lockVault() {
        if let currentVault = currentVault {
            lockVault(currentVault)
        } else {
            for vault in vaults where vault.isMounted {
                lockVault(vault)
            }
        }
    }
}
