import Foundation
import FileProvider
import UniformTypeIdentifiers
import CloudDriveCore
import CloudDriveStorage

extension FileProviderExtension {
    func configureAndLoadVault(_ vault: VaultInfo) {
        logInfo(.system, "⚙️ Configuring and loading vault: \(vault.name) (isEncrypted: \(vault.isEncrypted), type: \(vault.storageType.rawValue))")
        self.vfs = VirtualFileSystem(vaultId: vault.id)
        
        unlockTask = Task {
            guard vault.isStorageEnabled else {
                throw StorageError.notSupported("Only WebDAV is enabled")
            }
            let targetVault = vault
            
            // Prefer the saved WebDAV configuration.
            if let config = targetVault.storageConfig {
                let storagePassword = self.webdavPasswordFromUserInfo ?? self.getWebDAVPassword(for: targetVault.id) ?? ""
                let effectiveConfig = (config.secret ?? "").isEmpty && !storagePassword.isEmpty ? config.replacingSecret(storagePassword) : config
                if case .baidupan(let panConfig) = targetVault.storageConfig {
                    let tokenStore = BaiduPanTokenStore()
                    tokenStore.cloneCredentials(from: "default", to: targetVault.id)
                    if !panConfig.accessToken.isEmpty {
                        try? tokenStore.saveAuthorized(
                            vaultID: targetVault.id,
                            appID: panConfig.appID,
                            clientID: panConfig.appKey,
                            accessToken: panConfig.accessToken,
                            refreshToken: panConfig.refreshToken,
                            expiresIn: 25 * 86400
                        )
                        try? tokenStore.saveAuthorized(
                            vaultID: "default",
                            appID: panConfig.appID,
                            clientID: panConfig.appKey,
                            accessToken: panConfig.accessToken,
                            refreshToken: panConfig.refreshToken,
                            expiresIn: 25 * 86400
                        )
                    }
                }
                var finalVault = targetVault
                finalVault.storageConfig = effectiveConfig
                let client = StorageClientFactory.createClient(for: finalVault, fallbackPassword: storagePassword)
                self.vfs.configureStorage(client: client)
                
                let effectiveStoragePath = targetVault.storagePath.isEmpty ? "/" : targetVault.storagePath
                if targetVault.isEncrypted {
                    logInfo(.system, "🔐 Vault is encrypted mode, unlocking (path: \(effectiveStoragePath))...")
                    guard let vaultPassword = self.vaultPasswordFromUserInfo ?? self.getVaultPassword(for: targetVault.id) else {
                        logError(.system, "❌ Failed to get vault encryption password")
                        throw VFSError.vaultLocked
                    }
                    try await self.vfs.unlockVault(password: vaultPassword, storagePath: effectiveStoragePath, vaultId: targetVault.id)
                    logSuccess(.system, "✅ Encrypted vault unlocked successfully")
                } else {
                    logInfo(.system, "📂 Vault is direct mapping mode")
                    try await self.vfs.initializeDirectMappingVault(vaultId: targetVault.id, storagePath: effectiveStoragePath)
                    logSuccess(.system, "✅ Direct mapping vault initialized successfully")
                }
                await VaultIgnoreManager.shared.loadIgnoreRules(vaultId: targetVault.id, vfs: self.vfs)
                self.syncManager.recoverQueueOnUnlock()
                await EnumeratorSignaler.shared.signalImmediately(for: self.domain)
                return
            }
            
            if let webdavURL = targetVault.webdavURL,
               let webdavUsername = targetVault.webdavUsername,
               let url = URL(string: webdavURL) {
                
                logInfo(.webdav, "🔧 Configuring WebDAV storage")
                let password = self.webdavPasswordFromUserInfo ?? self.getWebDAVPassword(for: targetVault.id) ?? ""
                
                self.vfs.configureWebDAV(baseURL: url, username: webdavUsername, password: password)
                
                let effectiveStoragePath = targetVault.storagePath
                
                if targetVault.isEncrypted {
                    logInfo(.system, "🔐 Vault is encrypted mode, unlocking (path: \(effectiveStoragePath))...")
                    guard let vaultPassword = self.vaultPasswordFromUserInfo ?? self.getVaultPassword(for: targetVault.id) else {
                        logError(.system, "❌ Failed to get vault encryption password")
                        throw VFSError.vaultLocked
                    }
                    try await self.vfs.unlockVault(password: vaultPassword, storagePath: effectiveStoragePath, vaultId: targetVault.id)
                    logSuccess(.system, "✅ Encrypted vault unlocked successfully")
                } else {
                    logInfo(.system, "📂 Vault is direct mapping mode")
                    try await self.vfs.initializeDirectMappingVault(vaultId: targetVault.id, storagePath: effectiveStoragePath)
                    logSuccess(.system, "✅ Direct mapping vault initialized successfully")
                }
                await VaultIgnoreManager.shared.loadIgnoreRules(vaultId: targetVault.id, vfs: self.vfs)
                self.syncManager.recoverQueueOnUnlock()
                await EnumeratorSignaler.shared.signalImmediately(for: self.domain)
                return
            } else {
                throw StorageError.notConfigured
            }
        }
    }
    
    func getWebDAVPassword(for vaultId: String) -> String? {
        return CredentialStore.shared.getStoragePassword(for: vaultId)
    }
    
    func getVaultPassword(for vaultId: String) -> String? {
        return CredentialStore.shared.getVaultPassword(for: vaultId)
    }
    
}
