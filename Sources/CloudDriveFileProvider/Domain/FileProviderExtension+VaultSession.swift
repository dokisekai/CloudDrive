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
            var targetVault = vault
            
            // 1. Prefer unified multi-protocol storage configuration (S3, SMB, FTP, WebDAV, Local)
            if let config = targetVault.storageConfig {
                let storagePassword = self.webdavPasswordFromUserInfo ?? self.getWebDAVPassword(for: targetVault.id) ?? ""
                let effectiveConfig = (config.secret ?? "").isEmpty && !storagePassword.isEmpty ? config.replacingSecret(storagePassword) : config
                logInfo(.system, "🔧 Loading storage with multi-protocol config: \(effectiveConfig.summaryDescription)")
                let client = StorageClientFactory.createClient(configuration: effectiveConfig)
                self.vfs.configureStorage(client: client)
                
                let effectiveStoragePath = targetVault.storagePath.isEmpty ? "/" : targetVault.storagePath
                if targetVault.isEncrypted {
                    logInfo(.system, "🔐 Vault is encrypted mode, unlocking (path: \(effectiveStoragePath))...")
                    guard let vaultPassword = self.vaultPasswordFromUserInfo ?? self.getVaultPassword(for: targetVault.id) else {
                        logError(.system, "❌ Failed to get vault encryption password")
                        throw VFSError.invalidPassword
                    }
                    try await self.vfs.unlockVault(password: vaultPassword, storagePath: effectiveStoragePath, vaultId: targetVault.id)
                    logSuccess(.system, "✅ Encrypted vault unlocked successfully")
                } else {
                    logInfo(.system, "📂 Vault is direct mapping mode")
                    try await self.vfs.initializeDirectMappingVault(vaultId: targetVault.id, storagePath: effectiveStoragePath)
                    logSuccess(.system, "✅ Direct mapping vault initialized successfully")
                }
                await VaultIgnoreManager.shared.loadIgnoreRules(vaultId: targetVault.id, vfs: self.vfs)
                self.syncManager.processSyncQueue()
                await EnumeratorSignaler.shared.signalImmediately(for: self.domain)
                return
            }
            
            // If local storage vault without WebDAV URL, bridge to loopback port 28282 by default
            if targetVault.webdavURL == nil && (targetVault.isLocal || !targetVault.storagePath.isEmpty) {
                let fallbackURL = "http://127.0.0.1:28282/v/\(targetVault.id)/"
                logInfo(.system, "🌐 Extension: Local vault auto-bridging to loopback: \(fallbackURL)")
                targetVault.webdavURL = fallbackURL
                targetVault.webdavUsername = "local"
                if self.webdavPasswordFromUserInfo == nil {
                    self.webdavPasswordFromUserInfo = "local"
                }
            }
            
            if let webdavURL = targetVault.webdavURL,
               let webdavUsername = targetVault.webdavUsername,
               let url = URL(string: webdavURL) {
                
                logInfo(.webdav, "🔧 Configuring WebDAV storage: \(webdavURL)")
                let password = self.webdavPasswordFromUserInfo ?? self.getWebDAVPassword(for: targetVault.id) ?? "local"
                
                self.vfs.configureWebDAV(baseURL: url, username: webdavUsername, password: password)
                
                let isLoopback = webdavURL.contains("127.0.0.1") || webdavURL.contains("localhost")
                let effectiveStoragePath = isLoopback ? "/" : targetVault.storagePath
                
                if targetVault.isEncrypted {
                    logInfo(.system, "🔐 Vault is encrypted mode, unlocking (path: \(effectiveStoragePath))...")
                    guard let vaultPassword = self.vaultPasswordFromUserInfo ?? self.getVaultPassword(for: targetVault.id) else {
                        logError(.system, "❌ Failed to get vault encryption password")
                        throw VFSError.invalidPassword
                    }
                    try await self.vfs.unlockVault(password: vaultPassword, storagePath: effectiveStoragePath, vaultId: targetVault.id)
                    logSuccess(.system, "✅ Encrypted vault unlocked successfully")
                } else {
                    logInfo(.system, "📂 Vault is direct mapping mode")
                    try await self.vfs.initializeDirectMappingVault(vaultId: targetVault.id, storagePath: effectiveStoragePath)
                    logSuccess(.system, "✅ Direct mapping vault initialized successfully")
                }
                await VaultIgnoreManager.shared.loadIgnoreRules(vaultId: targetVault.id, vfs: self.vfs)
                self.syncManager.processSyncQueue()
                await EnumeratorSignaler.shared.signalImmediately(for: self.domain)
                return
            } else {
                // Local storage vault
                logInfo(.system, "📁 Configuring local storage vault: \(vault.storagePath)")
                logInfo(.system, "🔐 Local vault security bookmark status: bookmarkDataFromUserInfo=\(self.bookmarkDataFromUserInfo != nil), vault.bookmarkData=\(vault.bookmarkData != nil)")
                let localClient = LocalStorageClient()
                localClient.configureSecurityScope(
                    url: URL(fileURLWithPath: vault.storagePath),
                    bookmarkData: self.bookmarkDataFromUserInfo ?? vault.bookmarkData
                )
                self.vfs.configureStorage(client: localClient)
                logSuccess(.sync, "✅ Local storage client configured")
                
                if vault.isEncrypted {
                    logInfo(.system, "🔐 Local vault is encrypted mode, unlocking...")
                    guard let vaultPassword = self.vaultPasswordFromUserInfo ?? self.getVaultPassword(for: vault.id) else {
                        logError(.system, "❌ Failed to get local vault encryption password (vaultId: \(vault.id))")
                        throw VFSError.invalidPassword
                    }
                    do {
                        try await self.vfs.unlockVault(password: vaultPassword, storagePath: vault.storagePath, vaultId: vault.id)
                        logSuccess(.system, "✅ Local encrypted vault unlocked successfully")
                    } catch {
                        logError(.system, "❌ Local encrypted vault unlockVault failed: \(error)")
                        throw error
                    }
                }
            }
            await VaultIgnoreManager.shared.loadIgnoreRules(vaultId: targetVault.id, vfs: self.vfs)
            self.syncManager.processSyncQueue()
            await EnumeratorSignaler.shared.signalImmediately(for: self.domain)
        }
    }
    
    func getWebDAVPassword(for vaultId: String) -> String? {
        return CredentialStore.shared.getStoragePassword(for: vaultId)
    }
    
    func getVaultPassword(for vaultId: String) -> String? {
        return CredentialStore.shared.getVaultPassword(for: vaultId)
    }
    
}
