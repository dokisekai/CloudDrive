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
        print("🔗 AppState: Unified storage connection: [\(configuration.type.displayName)] Mode: \(mode.rawValue)")
        
        let vaultId = UUID().uuidString

        print("🆔 AppState: Generated vault ID: \(vaultId)")
        
        // 配置 VFS 与 SyncManager
        vfs.configureStorage(configuration: configuration)
        
        // 提取并保存密码/密钥
        let secret: String? = {
            switch configuration {
            case .webdav(let c): return c.password
            case .s3(let c): return c.secretKey
            case .smb(let c): return c.password
            case .ftp(let c): return c.password
            case .pan123(let c): return c.clientSecret
            case .local: return nil
            }
        }()
        
        if let sec = secret {
            saveWebDAVPassword(sec, for: vaultId)
        }
        if let vp = vaultPassword {
            saveVaultPassword(vp, for: vaultId)
        }
        saveCredentialsToAppGroup(vaultId: vaultId, webdavPassword: secret, vaultPassword: vaultPassword)
        
        let cleanRemotePath = remotePath.isEmpty ? "/" : remotePath
        switch mode {
        case .directWebDAV:
            try await vfs.initializeDirectMappingVault(vaultId: vaultId, storagePath: cleanRemotePath)
        case .createEncrypted:
            guard let vp = vaultPassword, !vp.isEmpty else {
                throw NSError(domain: "CloudDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: L("err_set_vault_password")])
            }
            _ = try await vfs.initializeVault(name: name, password: vp, storagePath: cleanRemotePath, vaultId: vaultId)
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
            ? "/" + (cleanRemotePath + "/" + name).split(separator: "/").joined(separator: "/")
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
