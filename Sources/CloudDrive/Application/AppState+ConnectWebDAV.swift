import SwiftUI
import CloudDriveCore
import CloudDriveStorage
import FileProvider
import Network

extension AppState {
    func connectWebDAVStorage(name: String, webdavURL: String, username: String, webdavPassword: String) async throws {
        print("🔗 AppState: Connecting WebDAV storage (direct mapping mode)")
        
        guard let url = URL(string: webdavURL) else {
            throw NSError(domain: "CloudDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: L("err_invalid_webdav_url")])
        }
        
        // 配置 WebDAV
        vfs.configureWebDAV(baseURL: url, username: username, password: webdavPassword)
        
        // 配置 SyncManager
        print("✅ AppState: Storage configured")
        
        let vaultId = UUID().uuidString

        print("🆔 AppState: Generated vault ID: \(vaultId)")
        
        // 保存密码到共享 Keychain，供 File Provider Extension 使用
        print("🔑 AppState: Saving password to Keychain...")
        saveWebDAVPassword(webdavPassword, for: vaultId)
        saveCredentialsToAppGroup(vaultId: vaultId, webdavPassword: webdavPassword, vaultPassword: nil)
        print("✅ AppState: Password saved to Keychain")
        
        // 初始化本地数据库（用于缓存文件列表）
        print("💾 AppState: Initializing local database...")
        do {
            // 创建一个简单的数据库来跟踪 WebDAV 文件
            try await vfs.initializeDirectMappingVault(vaultId: vaultId, storagePath: "/")
            print("✅ AppState: Database initialized successfully")
        } catch {
            print("❌ AppState: Database initialization failed: \(error)")
            throw error
        }
        
        // 保存保险库信息（不创建任何远程目录）
        let vaultInfo = VaultInfo(
            id: vaultId,
            name: name,
            storagePath: "/",  // 直接映射根目录
            createdAt: Date(),
            webdavURL: webdavURL,
            webdavUsername: username,
            isMounted: true,  // 创建后自动挂载
            isEncrypted: false
        )
        
        // 同时保存到共享文件，供 File Provider Extension 使用
        print("💾 AppState: Saving config to shared file...")
        saveVaultConfigToSharedFile(vaultInfo)
        print("✅ AppState: Config file saved")
        
        // 注册 File Provider Domain（在系统文件夹显示虚拟盘）
        print("📁 AppState: Registering File Provider domain...")
        do {
            try await registerFileProviderDomain(for: vaultInfo)
            print("✅ AppState: File Provider domain registered successfully")
        } catch {
            print("❌ AppState: File Provider domain registration failed: \(error)")
            // 不抛出错误，因为即使 Domain 注册失败，应用内浏览仍然可用
        }
        
        // 添加到列表并保存
        vaults.append(vaultInfo)
        saveVaults()
        
        // 自动挂载
        currentVault = vaultInfo
        isVaultUnlocked = true
        
        print("✅ AppState: WebDAV storage connected and mounted automatically")
        print("📁 AppState: Vault added to sidebar")
        
        // 触发文件列表同步到虚拟盘
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("🔄 AppState: Starting sync file list to virtual drive")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        Task {
            await syncFilesToFileProvider(vaultId: vaultId)
        }
    }
}
