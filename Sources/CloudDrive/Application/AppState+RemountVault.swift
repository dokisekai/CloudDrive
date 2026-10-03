import SwiftUI
import CloudDriveCore
import CloudDriveStorage
import FileProvider
import Network

extension AppState {
    func remountVault(_ vault: VaultInfo) async throws {
        print("📂 AppState: Remounting vault: \(vault.name)")
        
        // 检查是否已经挂载
        if vault.isMounted, currentVault?.id == vault.id {
            print("✅ AppState: Vault already mounted, skipping")
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
            } else if effectivePath == "/" {
                print("📂 AppState: Mounting with direct mapping mode")
                try await vfs.remountDirectMappingVault(vaultId: activeVault.id, storagePath: effectivePath)
            } else {
                try await vfs.mountVaultWithoutEncryption(storagePath: effectivePath, vaultId: activeVault.id)
            }
        } else if activeVault.isLocal || activeVault.webdavURL?.contains("127.0.0.1") == true {
            print("📂 AppState: Remounting local WebDAV vault: \(activeVault.name)")
            let localURL = URL(fileURLWithPath: activeVault.storagePath)
            
            // 确保本地目录有效
            if !FileManager.default.fileExists(atPath: activeVault.storagePath) && activeVault.bookmarkData == nil {
                let bookmark: Data? = await MainActor.run {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = false
                    panel.directoryURL = URL(fileURLWithPath: activeVault.storagePath)
                    panel.prompt = L("appstate_panel_prompt")
                    panel.message = L("appstate_panel_message")
                    if panel.runModal() == .OK, let url = panel.url {
                        return try? url.bookmarkData(
                            options: .withSecurityScope,
                            includingResourceValuesForKeys: nil,
                            relativeTo: nil
                        )
                    }
                    return nil
                }
                
                if let b = bookmark {
                    activeVault.bookmarkData = b
                    if let index = vaults.firstIndex(where: { $0.id == activeVault.id }) {
                        vaults[index] = activeVault
                        saveVaults()
                    }
                    if let sharedDefaults = UserDefaults(suiteName: "group.net.aabg.CloudDrive") {
                        sharedDefaults.set(b, forKey: "vault_bookmark_\(activeVault.id)")
                        sharedDefaults.set(b, forKey: "active_vault_bookmark")
                    }
                } else {
                    throw NSError(domain: "CloudDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: L("err_no_local_folder_auth")])
                }
            }
            
            LocalWebDAVServer.shared.start()
            LocalWebDAVServer.shared.register(vaultId: activeVault.id, localURL: localURL)
            let localBaseURL = LocalWebDAVServer.shared.baseURL(for: activeVault.id).absoluteString
            
            if activeVault.webdavURL != localBaseURL || activeVault.webdavUsername != "local" {
                activeVault.webdavURL = localBaseURL
                activeVault.webdavUsername = "local"
                if let index = vaults.firstIndex(where: { $0.id == activeVault.id }) {
                    vaults[index] = activeVault
                    saveVaults()
                }
                saveWebDAVPassword("local", for: activeVault.id)
            }
            
            vfs.configureWebDAV(baseURL: URL(string: localBaseURL)!, username: "local", password: "local")
            
            if activeVault.isEncrypted {
                guard let vaultPassword = getVaultPassword(for: activeVault.id) else {
                    throw NSError(domain: "CloudDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: L("err_cannot_get_password")])
                }
                saveCredentialsToAppGroup(vaultId: activeVault.id, webdavPassword: "local", vaultPassword: vaultPassword)
                try await vfs.unlockVault(password: vaultPassword, storagePath: "/", vaultId: activeVault.id)
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
            } else if vault.storagePath == "/" {
                print("📂 AppState: Mounting with direct mapping mode")
                // 使用直接映射模式挂载
                try await vfs.remountDirectMappingVault(vaultId: vault.id, storagePath: vault.storagePath)
            } else {
                print("📂 AppState: Mounting with legacy mode")
                // 使用传统模式挂载（无加密）
                try await vfs.mountVaultWithoutEncryption(storagePath: vault.storagePath, vaultId: vault.id)
            }
        }
        
        // 更新当前保险库和状态
        currentVault = activeVault
        isVaultUnlocked = true
        saveVaultConfigToSharedFile(activeVault)
        saveCredentialsToAppGroup(
            vaultId: activeVault.id,
            webdavPassword: activeVault.webdavUsername != nil ? getWebDAVPassword(for: activeVault.id) : nil,
            vaultPassword: activeVault.isEncrypted ? getVaultPassword(for: activeVault.id) : nil
        )
        
        // 更新挂载状态
        if let index = vaults.firstIndex(where: { $0.id == activeVault.id }) {
            // 创建新的 VaultInfo 实例，触发 SwiftUI 更新
            var updatedVault = vaults[index]
            updatedVault.isMounted = true
            vaults[index] = updatedVault
            saveVaults()
        }
        
        // 确保 Domain 已经被注册
        do {
            try await registerFileProviderDomain(for: activeVault)
        } catch {
            NSLog("⚠️ AppState: Domain registration failed during remount: %@", error as NSError)
        }

        Task {
            await syncFilesToFileProvider(vaultId: activeVault.id)
        }

        print("✅ AppState: Vault remounted successfully")
    }
}
