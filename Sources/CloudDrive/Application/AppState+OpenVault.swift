import SwiftUI
import CloudDriveCore
import CloudDriveStorage
import FileProvider
import Network

extension AppState {
    func openExistingEncryptedVault(
        name: String,
        webdavURL: String,
        username: String,
        webdavPassword: String,
        remotePath: String,
        vaultPassword: String
    ) async throws {
        print("🔓 AppState: Opening existing encrypted vault...")
        print("   Name: \(name)")
        print("   URL: \(webdavURL)")
        print("   Remote path: \(remotePath)")
        
        guard let url = URL(string: webdavURL) else {
            throw NSError(domain: "CloudDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: L("err_invalid_webdav_url")])
        }
        
        // 1. 配置 WebDAV
        vfs.configureWebDAV(baseURL: url, username: username, password: webdavPassword)
        
        // 配置 SyncManager
        let webdavClient = WebDAVClient(baseURL: url, username: username, password: webdavPassword)
        print("✅ AppState: WebDAV configured")
        
        // 测试连接
        let connected = try await webdavClient.testConnection()
        guard connected else {
            throw NSError(domain: "CloudDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: L("err_cannot_connect_webdav")])
        }
        
        // 2. 规范化远端路径
        var cleanPath = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanPath.isEmpty || cleanPath == "/" {
            cleanPath = "/"
        } else {
            if !cleanPath.hasPrefix("/") {
                cleanPath = "/" + cleanPath
            }
            while cleanPath.hasSuffix("/") && cleanPath.count > 1 {
                cleanPath = String(cleanPath.dropLast())
            }
        }
        
        // 3. 生成保险库唯一 ID
        let folderName = cleanPath == "/" ? "root" : (URL(fileURLWithPath: cleanPath).lastPathComponent)
        let sanitizedFolderName = folderName.filter { $0.isLetter || $0.isNumber }
        let vaultId = "vault_\(sanitizedFolderName.isEmpty ? "v" : sanitizedFolderName)_\(UUID().uuidString.prefix(6).lowercased())"
        print("🆔 AppState: Generated vault ID: \(vaultId)")
        
        // 4. 尝试解锁验证密码及格式
        print("🔑 AppState: Attempting to verify password and unlock vault...")
        try await vfs.unlockVault(password: vaultPassword, storagePath: cleanPath, vaultId: vaultId)
        print("✅ AppState: Password verified successfully, vault unlocked!")
        
        // 5. 保存密码到 Keychain
        saveWebDAVPassword(webdavPassword, for: vaultId)
        saveVaultPassword(vaultPassword, for: vaultId)
        saveCredentialsToAppGroup(vaultId: vaultId, webdavPassword: webdavPassword, vaultPassword: vaultPassword)
        print("🔑 AppState: Credentials saved to Keychain and AppGroup")
        
        // 6. 保存保险库信息
        let vaultInfo = VaultInfo(
            id: vaultId,
            name: name,
            storagePath: cleanPath,
            createdAt: Date(),
            webdavURL: webdavURL,
            webdavUsername: username,
            isMounted: true,
            isEncrypted: true
        )
        
        saveVaultConfigToSharedFile(vaultInfo)
        
        // 7. 注册 File Provider Domain
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
        
        print("✅ AppState: Existing encrypted vault imported and mounted successfully")
        Task {
            await syncFilesToFileProvider(vaultId: vaultId)
        }
    }
}
