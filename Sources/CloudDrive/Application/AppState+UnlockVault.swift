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
        
        print("🔓 AppState: Mounting vault: \(vault.name)")
        
        // 配置存储
        if let config = vault.storageConfig {
            let storagePassword = vault.isEncrypted ? (getWebDAVPassword(for: vaultId) ?? "") : password
            let effectiveConfig = (config.secret ?? "").isEmpty && !storagePassword.isEmpty ? config.replacingSecret(storagePassword) : config
            print("⚙️ AppState: Configuring storage for vault [\(effectiveConfig.type.displayName)]: \(effectiveConfig.summaryDescription)")
            vfs.configureStorage(configuration: effectiveConfig)
        } else if vault.isLocal || vault.webdavURL?.contains("127.0.0.1") == true {
            print("📁 AppState: Mounting local WebDAV vault: \(vault.storagePath)")
            let localURL = URL(fileURLWithPath: vault.storagePath)
            LocalWebDAVServer.shared.start()
            LocalWebDAVServer.shared.register(vaultId: vault.id, localURL: localURL)
            let localBaseURL = LocalWebDAVServer.shared.baseURL(for: vault.id).absoluteString
            
            vfs.configureWebDAV(baseURL: URL(string: localBaseURL)!, username: "local", password: "local")
            print("✅ AppState: Local WebDAV loopback storage configured")
        } else if let webdavURL = vault.webdavURL,
           let webdavUsername = vault.webdavUsername,
           let url = URL(string: webdavURL) {
            let webdavPassword = vault.isEncrypted ? (getWebDAVPassword(for: vaultId) ?? password) : password
            vfs.configureWebDAV(baseURL: url, username: webdavUsername, password: webdavPassword)
            
            // 配置 SyncManager
            print("✅ AppState: Storage configured")
        }
        
        let isLoopback = vault.isLocal || vault.webdavURL?.contains("127.0.0.1") == true
        let effectiveStoragePath = isLoopback ? "/" : vault.storagePath
        
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
        
        // 更新挂载状态
        if let index = vaults.firstIndex(where: { $0.id == vaultId }) {
            // 创建新的 VaultInfo 实例，触发 SwiftUI 更新
            var updatedVault = vaults[index]
            updatedVault.isMounted = true
            vaults[index] = updatedVault
            saveVaults()
        }
        
        // 注册 FileProvider Domain 并刷新
        do {
            try await registerFileProviderDomain(for: vault)
        } catch {
            NSLog("⚠️ AppState: Domain registration failed during unlock: %@", error as NSError)
        }
        
        Task {
            await syncFilesToFileProvider(vaultId: vaultId)
        }
        
        postSystemNotification(title: "CloudDrive", body: "存储库「\(vault.name)」已成功挂载")
        print("✅ AppState: Vault mounted successfully")
    }

    func lockVault() {
        print("🔒 AppState: Locking vault")
        let lockedName = currentVault?.name
        
        // 更新挂载状态
        if let currentVault = currentVault,
           let index = vaults.firstIndex(where: { $0.id == currentVault.id }) {
            // 创建新的 VaultInfo 实例，触发 SwiftUI 更新
            var updatedVault = vaults[index]
            updatedVault.isMounted = false
            vaults[index] = updatedVault
            saveVaults()
        }
        
        // 调用VFS的锁定方法，清除主密钥和重置数据库
        vfs.lock()
        
        isVaultUnlocked = false
        currentVault = nil
        
        // 清除解锁相关的状态，确保可以再次解锁
        showUnlockVault = false
        selectedVaultForUnlock = nil
        
        if let name = lockedName {
            postSystemNotification(title: "CloudDrive", body: "存储库「\(name)」已安全锁定")
        }
        print("✅ AppState: Vault locked")
    }
}
