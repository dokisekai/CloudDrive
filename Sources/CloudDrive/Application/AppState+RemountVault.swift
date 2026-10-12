import SwiftUI
import CloudDriveCore
import CloudDriveStorage
import FileProvider
import Network

extension AppState {
    func remountVault(_ vault: VaultInfo) async throws {
        guard vault.isStorageEnabled else {
            throw StorageError.notSupported("Only WebDAV is enabled")
        }
        print("📂 AppState: Remounting vault: \(vault.name)")
        
        // 检查是否已经挂载且驱动正常活跃
        if vault.isMounted, currentVault?.id == vault.id, vfs.activeProvider != nil {
            print("✅ AppState: Vault already mounted and provider active, skipping")
            return
        }
        
        var activeVault = vault
        if let config = activeVault.storageConfig {
            let storagePassword = getWebDAVPassword(for: activeVault.id) ?? ""
            let effectiveConfig = (config.secret ?? "").isEmpty && !storagePassword.isEmpty ? config.replacingSecret(storagePassword) : config
            print("⚙️ AppState: Remounting multi-protocol vault [\(effectiveConfig.type.displayName)]: \(effectiveConfig.summaryDescription)")
            vfs.configureStorage(configuration: effectiveConfig)

            
            let effectivePath = activeVault.storagePath.isEmpty ? "/" : activeVault.storagePath
            if activeVault.isEncrypted {
                print("📂 AppState: Mounting with encrypted mode")
                guard let vaultPassword = getVaultPassword(for: activeVault.id) else {
                    throw NSError(domain: "CloudDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: L("err_cannot_get_password")])
                }
                try await vfs.unlockVault(password: vaultPassword, storagePath: effectivePath, vaultId: activeVault.id)
                activeVault.isUnlocked = true
            } else if effectivePath == "/" {
                print("📂 AppState: Mounting with direct mapping mode")
                try await vfs.remountDirectMappingVault(vaultId: activeVault.id, storagePath: effectivePath)
                activeVault.isUnlocked = true
            } else {
                try await vfs.mountVaultWithoutEncryption(storagePath: effectivePath, vaultId: activeVault.id)
                activeVault.isUnlocked = true
            }
        } else {
            guard let webdavURL = vault.webdavURL,
                  let webdavUsername = vault.webdavUsername else {
                throw NSError(domain: "CloudDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: L("err_incomplete_vault_config")])
            }
            
            // 从 Keychain 获取 WebDAV 密码
            guard let webdavPassword = getWebDAVPassword(for: vault.id) else {
                throw NSError(domain: "CloudDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: L("err_cannot_get_webdav_password")])
            }
            
            print("✅ AppState: Retrieved password from Keychain")
            
            guard let url = URL(string: webdavURL) else {
                throw NSError(domain: "CloudDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: L("err_invalid_webdav_url")])
            }
            
            // 配置 WebDAV
            vfs.configureWebDAV(baseURL: url, username: webdavUsername, password: webdavPassword)
            
            // 配置 SyncManager
            print("✅ AppState: Storage configured")
            
            if vault.isEncrypted {
                print("📂 AppState: Mounting with encrypted mode")
                guard let vaultPassword = getVaultPassword(for: vault.id) else {
                    throw NSError(domain: "CloudDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: L("err_cannot_get_password")])
                }
                try await vfs.unlockVault(password: vaultPassword, storagePath: vault.storagePath, vaultId: vault.id)
                activeVault.isUnlocked = true
            } else if vault.storagePath == "/" {
                print("📂 AppState: Mounting with direct mapping mode")
                // 使用直接映射模式挂载
                try await vfs.remountDirectMappingVault(vaultId: vault.id, storagePath: vault.storagePath)
                activeVault.isUnlocked = true
            } else {
                print("📂 AppState: Mounting with legacy mode")
                // 使用传统模式挂载（无加密）
                try await vfs.mountVaultWithoutEncryption(storagePath: vault.storagePath, vaultId: vault.id)
                activeVault.isUnlocked = true
            }
        }
        
        // 更新当前保险库和状态
        currentVault = activeVault
        isVaultUnlocked = activeVault.isUnlocked
        saveVaultConfigToSharedFile(activeVault)
        saveCredentialsToAppGroup(
            vaultId: activeVault.id,
            webdavPassword: activeVault.webdavUsername != nil ? getWebDAVPassword(for: activeVault.id) : nil,
            vaultPassword: (activeVault.isEncrypted && activeVault.isUnlocked) ? getVaultPassword(for: activeVault.id) : nil
        )
        
        // 更新挂载与解锁状态
        if let index = vaults.firstIndex(where: { $0.id == activeVault.id }) {
            // 创建新的 VaultInfo 实例，触发 SwiftUI 更新
            var updatedVault = vaults[index]
            updatedVault.isMounted = true
            updatedVault.isUnlocked = activeVault.isUnlocked
            updatedVault.isAutoMount = true
            vaults[index] = updatedVault
            saveVaults()
        }
        
        // 确保 Domain 已经被注册
        do {
            try await registerFileProviderDomain(for: activeVault)
        } catch {
            NSLog("⚠️ AppState: Domain registration failed during remount: %@", error as NSError)
        }
        
        // 恢复并重跑同步队列，重置在途与鉴权失败任务
        SyncManager.forVault(activeVault.id).recoverQueueOnUnlock()
        
        let sharedDefaults = UserDefaults(suiteName: "group.net.aabg.CloudDrive")
        sharedDefaults?.removeObject(forKey: "lockedVaultId")
        sharedDefaults?.set(activeVault.id, forKey: "unlockedVaultId")
        sharedDefaults?.synchronize()

        // 广播挂载通知
        FileProviderSync.shared.notifyVaultUnlocked(vaultId: activeVault.id)
        let center = DistributedNotificationCenter.default()
        center.postNotificationName(
            NSNotification.Name("net.aabg.CloudDrive.vaultUnlocked"),
            object: nil,
            userInfo: ["vaultId": activeVault.id],
            deliverImmediately: true
        )

        Task {
            await syncFilesToFileProvider(vaultId: activeVault.id)
        }

        postSystemNotification(title: "CloudDrive", body: "存储库「\(activeVault.name)」已成功挂载")
        print("✅ AppState: Vault remounted successfully")
    }
}
