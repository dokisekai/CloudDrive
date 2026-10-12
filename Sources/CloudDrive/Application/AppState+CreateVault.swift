import SwiftUI
import CloudDriveCore
import CloudDriveStorage
import FileProvider
import Network

extension AppState {
    func createVault(name: String, webdavURL: String, username: String, webdavPassword: String) async throws {
        print("🔧 AppState: Creating WebDAV vault (unencrypted mode)")
        
        guard let url = URL(string: webdavURL) else {
            throw NSError(domain: "CloudDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: L("err_invalid_webdav_url")])
        }
        
        // 配置 WebDAV
        vfs.configureWebDAV(baseURL: url, username: username, password: webdavPassword)
        
        // 配置 SyncManager
        print("✅ AppState: Storage configured")
        
        let vaultId = try await vfs.initializeVaultWithoutEncryption(name: name, storagePath: "/")
        
        // 保存保险库信息
        let vaultInfo = VaultInfo(
            id: vaultId,
            name: name,
            storagePath: "/",
            createdAt: Date(),
            webdavURL: webdavURL,
            webdavUsername: username
        )
        
        var mutableVaultInfo = vaultInfo
        mutableVaultInfo.isMounted = true
        vaults.append(mutableVaultInfo)
        saveVaults()
        
        // 自动挂载（解锁）
        currentVault = mutableVaultInfo
        isVaultUnlocked = true
        
        print("✅ AppState: WebDAV vault created and mounted successfully")
    }

    func createEncryptedVault(name: String, webdavURL: String, username: String, webdavPassword: String, vaultPassword: String) async throws {
        print("🔐 AppState: Creating encrypted vault (AES-GCM mode)")
        
        guard let url = URL(string: webdavURL) else {
            throw NSError(domain: "CloudDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: L("err_invalid_webdav_url")])
        }
        
        // 配置 WebDAV
        vfs.configureWebDAV(baseURL: url, username: username, password: webdavPassword)
        
        // 配置 SyncManager
        print("✅ AppState: Storage configured")
        
        // 初始化加密保险库
        let storagePath = "/" + name
        let vaultId = try await vfs.initializeVault(name: name, password: vaultPassword, storagePath: storagePath, vaultId: UUID().uuidString)
        print("🆔 AppState: Encrypted vault initialized successfully, ID: \(vaultId)")
        
        // 保存密码到 Keychain
        saveWebDAVPassword(webdavPassword, for: vaultId)
        saveVaultPassword(vaultPassword, for: vaultId)
        saveCredentialsToAppGroup(vaultId: vaultId, webdavPassword: webdavPassword, vaultPassword: vaultPassword)
        print("🔑 AppState: Credentials saved to Keychain and AppGroup")
        
        // 保存保险库信息
        let vaultInfo = VaultInfo(
            id: vaultId,
            name: name,
            storagePath: storagePath,
            createdAt: Date(),
            webdavURL: webdavURL,
            webdavUsername: username,
            isMounted: true,
            isEncrypted: true
        )
        
        // 保存配置到共享文件
        saveVaultConfigToSharedFile(vaultInfo)
        
        // 注册 File Provider Domain
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
        
        print("✅ AppState: Encrypted vault created and mounted successfully")
        Task {
            await syncFilesToFileProvider(vaultId: vaultId)
        }
    }
}
