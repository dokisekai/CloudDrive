import SwiftUI
import CloudDriveCore
import CloudDriveStorage
import FileProvider
import Network

extension AppState {
    func connectUnifiedStorage(
        name: String,
        mode: VaultCreationMode,
        configuration: StorageConfiguration,
        remotePath: String = "/",
        vaultPassword: String? = nil,
        isAutoMount: Bool = true,
        bookmarkData: Data? = nil
    ) async throws {
        guard configuration.type.isAvailable else {
            throw StorageError.notSupported("Only WebDAV is enabled")
        }
        print("🔗 AppState: Unified storage connection: [\(configuration.type.displayName)] Mode: \(mode.rawValue)")
        
        let vaultId = UUID().uuidString

        print("🆔 AppState: Generated vault ID: \(vaultId)")
        
        // 若为百度网盘存储，将当前 default 模板凭据克隆至新生成的 vaultId，避免重复刷新消耗 token
        if case .baidupan(let panConfig) = configuration {
            let tokenStore = BaiduPanTokenStore()
            tokenStore.cloneCredentials(from: "default", to: vaultId)
            if !panConfig.accessToken.isEmpty {
                try? tokenStore.saveAuthorized(
                    vaultID: vaultId,
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

        // 配置 VFS 与 SyncManager
        vfs.configureStorage(configuration: configuration)
        
        // 提取并保存密码/密钥
        let secret: String? = configuration.secret
        
        if let sec = secret {
            saveWebDAVPassword(sec, for: vaultId)
        }
        if let vp = vaultPassword {
            saveVaultPassword(vp, for: vaultId)
        }
        saveCredentialsToAppGroup(vaultId: vaultId, webdavPassword: secret, vaultPassword: vaultPassword)
        
        let cleanRemotePath = remotePath.isEmpty ? "/" : remotePath
        let encryptedTargetVaultPath = "/" + (cleanRemotePath + "/" + name).split(separator: "/").joined(separator: "/")

        switch mode {
        case .directWebDAV:
            try await vfs.initializeDirectMappingVault(vaultId: vaultId, storagePath: cleanRemotePath)
        case .createEncrypted:
            guard let vp = vaultPassword, !vp.isEmpty else {
                throw NSError(domain: "CloudDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: L("err_set_vault_password")])
            }
            _ = try await vfs.initializeVault(name: name, password: vp, storagePath: encryptedTargetVaultPath, vaultId: vaultId)
        case .openExisting:
            guard let vp = vaultPassword, !vp.isEmpty else {
                throw NSError(domain: "CloudDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: L("err_enter_vault_password")])
            }
            try await vfs.unlockVault(password: vp, storagePath: cleanRemotePath, vaultId: vaultId)
        }
        
        var fallbackWebDAVURL: String? = nil
        var fallbackWebDAVUser: String? = nil
        if case .webdav(let wc) = configuration {
            fallbackWebDAVURL = wc.baseURL
            fallbackWebDAVUser = wc.username
        }
        
        let persistedPath = mode == .createEncrypted
            ? encryptedTargetVaultPath
            : cleanRemotePath
        let vaultInfo = VaultInfo(
            id: vaultId,
            name: name,
            storagePath: persistedPath,
            createdAt: Date(),
            storageType: configuration.type,
            storageConfig: configuration,
            webdavURL: fallbackWebDAVURL,
            webdavUsername: fallbackWebDAVUser,
            isMounted: true,
            isEncrypted: (mode != .directWebDAV),
            bookmarkData: bookmarkData,
            isAutoMount: isAutoMount
        )
        
        saveVaultConfigToSharedFile(vaultInfo)
        
        do {
            try await registerFileProviderDomain(for: vaultInfo)
            print("✅ AppState: File Provider domain registered successfully")
        } catch {
            print("❌ AppState: File Provider domain registration failed: \(error)")
        }
        
        vaults.append(vaultInfo)
        saveVaults()
        
        currentVault = vaultInfo
        isVaultUnlocked = true
        
        Task {
            await syncFilesToFileProvider(vaultId: vaultId)
        }
    }
}
