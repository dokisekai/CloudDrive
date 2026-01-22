//
//  AppState.swift
//  CloudDrive
//
//  应用状态管理
//

import SwiftUI
import CloudDriveCore
import FileProvider

/// 应用状态
@MainActor
class AppState: ObservableObject {
    @Published var vaults: [VaultInfo] = []
    @Published var isVaultUnlocked = false
    @Published var currentVault: VaultInfo?
    
    @Published var showCreateVault = false
    @Published var showUnlockVault = false
    @Published var selectedVaultForUnlock: VaultInfo?
    
    private let vfs = VirtualFileSystem.shared
    private let userDefaults = UserDefaults.standard
    private let vaultsKey = "savedVaults"
    
    init() {
        NSLog("🚀 AppState: 初始化中...")
        loadVaults()
        NSLog("✅ AppState: 初始化完成")
    }
    
    // MARK: - WebDAV Connection Test
    
    /// 测试 WebDAV 连接
    func testWebDAVConnection(url: String, username: String, password: String) async throws -> Bool {
        print("🔍 AppState: 测试 WebDAV 连接...")
        
        guard let webdavURL = URL(string: url) else {
            throw NSError(domain: "CloudDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 WebDAV URL"])
        }
        
        // 配置 WebDAV
        let client = WebDAVClient.shared
        client.configure(baseURL: webdavURL, username: username, password: password)
        
        // 测试连接
        let success = try await client.testConnection()
        
        print(success ? "✅ AppState: WebDAV 连接测试成功" : "❌ AppState: WebDAV 连接测试失败")
        return success
    }
    
    // MARK: - Vault Management
    
    /// 连接 WebDAV 存储（直接映射，不创建目录）
    func connectWebDAVStorage(name: String, webdavURL: String, username: String, webdavPassword: String) async throws {
        print("🔗 AppState: 连接 WebDAV 存储（直接映射模式）")
        
        guard let url = URL(string: webdavURL) else {
            throw NSError(domain: "CloudDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 WebDAV URL"])
        }
        
        // 配置 WebDAV
        vfs.configureWebDAV(baseURL: url, username: username, password: webdavPassword)
        
        // 配置 SyncManager
        let webdavClient = WebDAVClient.shared
        let storageClient = WebDAVStorageAdapter(webDAVClient: webdavClient)
        SyncManager.shared.configure(storageClient: storageClient)
        print("✅ AppState: SyncManager 已配置")
        
        // 使用 WebDAV URL 的哈希作为固定的保险库 ID
        // 这样同一个 WebDAV 服务器总是使用相同的 ID
        let vaultId = webdavURL.data(using: .utf8)!.base64EncodedString()
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "+", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .prefix(32)
            .description
        
        print("🆔 AppState: 使用固定的保险库 ID: \(vaultId)")
        
        // 保存密码到共享 Keychain，供 File Provider Extension 使用
        print("🔑 AppState: 保存密码到 Keychain...")
        saveWebDAVPassword(webdavPassword, for: vaultId)
        print("✅ AppState: 密码已保存到 Keychain")
        
        // 初始化本地数据库（用于缓存文件列表）
        print("💾 AppState: 初始化本地数据库...")
        do {
            // 创建一个简单的数据库来跟踪 WebDAV 文件
            try await vfs.initializeDirectMappingVault(vaultId: vaultId, storagePath: "/")
            print("✅ AppState: 数据库初始化成功")
        } catch {
            print("❌ AppState: 数据库初始化失败: \(error)")
            throw error
        }
        
        // 保存保险库信息（不创建任何远程目录）
        var vaultInfo = VaultInfo(
            id: vaultId,
            name: name,
            storagePath: "/",  // 直接映射根目录
            createdAt: Date(),
            webdavURL: webdavURL,
            webdavUsername: username,
            isMounted: true  // 创建后自动挂载
        )
        
        // 同时保存到共享文件，供 File Provider Extension 使用
        print("💾 AppState: 保存配置到共享文件...")
        saveVaultConfigToSharedFile(vaultInfo)
        print("✅ AppState: 配置文件已保存")
        
        // 注册 File Provider Domain（在系统文件夹显示虚拟盘）
        print("📁 AppState: 注册 File Provider Domain...")
        do {
            try await registerFileProviderDomain(for: vaultInfo)
            print("✅ AppState: File Provider Domain 注册成功")
        } catch {
            print("❌ AppState: File Provider Domain 注册失败: \(error)")
            // 不抛出错误，因为即使 Domain 注册失败，应用内浏览仍然可用
        }
        
        // 添加到列表并保存
        vaults.append(vaultInfo)
        saveVaults()
        
        // 自动挂载
        currentVault = vaultInfo
        isVaultUnlocked = true
        
        print("✅ AppState: WebDAV 存储连接成功并已自动挂载")
        print("📁 AppState: 保险库已添加到侧边栏")
        
        // 触发文件列表同步到虚拟盘
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("🔄 AppState: 开始同步文件列表到虚拟盘")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        Task {
            await syncFilesToFileProvider(vaultId: vaultId)
        }
    }
    
    /// 保存保险库配置到共享文件
    private func saveVaultConfigToSharedFile(_ vault: VaultInfo) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.net.aabg.CloudDrive"
        ) else {
            print("❌ AppState: 无法获取 App Group 容器 URL")
            return
        }
        
        let configURL = containerURL.appendingPathComponent("vault_config.json")
        print("📁 AppState: 配置文件路径: \(configURL.path)")
        
        do {
            let data = try JSONEncoder().encode(vault)
            try data.write(to: configURL, options: [.atomic])
            print("✅ AppState: 配置文件写入成功，大小: \(data.count) 字节")
            
            // 验证文件是否存在
            if FileManager.default.fileExists(atPath: configURL.path) {
                print("✅ AppState: 配置文件验证成功")
            } else {
                print("❌ AppState: 配置文件验证失败")
            }
        } catch {
            print("❌ AppState: 配置文件写入失败: \(error)")
        }
    }
    
    /// 保存 WebDAV 密码到共享 Keychain
    private func saveWebDAVPassword(_ password: String, for vaultId: String) {
        let passwordData = password.data(using: .utf8)!
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "webdav-password-\(vaultId)",
            kSecAttrService as String: "net.aabg.CloudDrive",
            kSecValueData as String: passwordData,
            kSecAttrAccessGroup as String: "group.net.aabg.CloudDrive"
        ]
        
        // 先删除旧的
        SecItemDelete(query as CFDictionary)
        
        // 添加新的
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            print("✅ Keychain: 密码保存成功")
        } else {
            print("❌ Keychain: 密码保存失败，状态码: \(status)")
        }
    }
    
    /// 同步文件列表到 File Provider
    private func syncFilesToFileProvider(vaultId: String) async {
        print("📡 AppState: 开始从 WebDAV 获取文件列表...")
        
        do {
            // 获取根目录文件列表
            let files = try vfs.listDirectory(directoryId: "ROOT")
            print("✅ AppState: 获取到 \(files.count) 个文件/文件夹")
            
            for file in files {
                print("   \(file.isDirectory ? "📁" : "📄") \(file.name) (\(file.size) 字节)")
            }
            
            // 通知 File Provider 刷新
            let domainIdentifier = NSFileProviderDomainIdentifier(rawValue: "vault-\(vaultId)")
            let domain = NSFileProviderDomain(identifier: domainIdentifier, displayName: "WebDAV 存储")
            
            if let manager = NSFileProviderManager(for: domain) {
                print("🔄 AppState: 通知 File Provider 刷新...")
                try await manager.signalEnumerator(for: NSFileProviderItemIdentifier.rootContainer)
                print("✅ AppState: File Provider 刷新信号已发送")
            } else {
                print("⚠️ AppState: 无法获取 File Provider Manager")
            }
            
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("✅ AppState: 文件列表同步完成")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            
        } catch {
            print("❌ AppState: 文件列表同步失败: \(error)")
            print("   错误详情: \(error.localizedDescription)")
        }
    }
    
    /// 注册 File Provider Domain
    private func registerFileProviderDomain(for vault: VaultInfo) async throws {
        let domainIdentifier = NSFileProviderDomainIdentifier(rawValue: "vault-\(vault.id)")
        let domain = NSFileProviderDomain(identifier: domainIdentifier, displayName: vault.name)
        
        print("📝 AppState: 创建 Domain - ID: \(domainIdentifier.rawValue), 名称: \(vault.name)")
        
        // 获取所有已存在的 Domain
        let existingDomains = try await NSFileProviderManager.domains()
        print("📋 AppState: 找到 \(existingDomains.count) 个已存在的 Domain")
        
        // 移除所有已存在的 Domain（清理旧的）
        for existingDomain in existingDomains {
            print("🗑️ AppState: 移除 Domain: \(existingDomain.identifier.rawValue)")
            do {
                try await NSFileProviderManager.remove(existingDomain)
                print("✅ AppState: Domain 移除成功")
            } catch {
                print("⚠️ AppState: Domain 移除失败: \(error.localizedDescription)")
            }
        }
        
        // 等待确保所有 Domain 都被移除
        if !existingDomains.isEmpty {
            print("⏳ AppState: 等待 Domain 清理完成...")
            try await Task.sleep(nanoseconds: 3_000_000_000) // 3秒
        }
        
        // 添加新的 Domain
        do {
            try await NSFileProviderManager.add(domain)
            print("✅ AppState: Domain 已添加到系统")
        } catch let error as NSError where error.code == 516 {
            // 如果仍然存在，说明是同一个 Domain，可以忽略
            print("ℹ️ AppState: Domain 已存在，跳过创建")
        } catch {
            print("❌ AppState: Domain 添加失败: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// 创建 WebDAV 保险库（无加密）
    func createVault(name: String, webdavURL: String, username: String, webdavPassword: String) async throws {
        print("🔧 AppState: 创建 WebDAV 保险库（无加密模式）")
        
        guard let url = URL(string: webdavURL) else {
            throw NSError(domain: "CloudDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的 WebDAV URL"])
        }
        
        // 配置 WebDAV
        vfs.configureWebDAV(baseURL: url, username: username, password: webdavPassword)
        
        // 配置 SyncManager
        let webdavClient = WebDAVClient.shared
        let storageClient = WebDAVStorageAdapter(webDAVClient: webdavClient)
        SyncManager.shared.configure(storageClient: storageClient)
        print("✅ AppState: SyncManager 已配置")
        
        // 初始化保险库（无加密）
        let vaultId = try await vfs.initializeVaultWithoutEncryption(storagePath: "/")
        
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
        
        print("✅ AppState: WebDAV 保险库创建成功并已自动挂载")
    }
    
    /// 挂载保险库（无加密模式，需要 WebDAV 密码）
    func unlockVault(vaultId: String, password: String) async throws {
        guard let vault = vaults.first(where: { $0.id == vaultId }) else {
            throw NSError(domain: "CloudDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: "保险库不存在"])
        }
        
        print("🔓 AppState: 挂载保险库: \(vault.name)")
        
        // 配置 WebDAV 存储（password 是 WebDAV 密码）
        if let webdavURL = vault.webdavURL,
           let webdavUsername = vault.webdavUsername,
           let url = URL(string: webdavURL) {
            vfs.configureWebDAV(baseURL: url, username: webdavUsername, password: password)
            
            // 配置 SyncManager
            let webdavClient = WebDAVClient.shared
            let storageClient = WebDAVStorageAdapter(webDAVClient: webdavClient)
            SyncManager.shared.configure(storageClient: storageClient)
            print("✅ AppState: SyncManager 已配置")
        }
        
        // 挂载保险库（无加密）
        try await vfs.mountVaultWithoutEncryption(storagePath: vault.storagePath, vaultId: vaultId)
        
        currentVault = vault
        isVaultUnlocked = true
        
        // 更新挂载状态
        if let index = vaults.firstIndex(where: { $0.id == vaultId }) {
            vaults[index].isMounted = true
            saveVaults()
        }
        
        print("✅ AppState: 保险库挂载成功")
    }
    
    /// 锁定保险库
    func lockVault() {
        print("🔒 AppState: 锁定保险库")
        
        // 更新挂载状态
        if let currentVault = currentVault,
           let index = vaults.firstIndex(where: { $0.id == currentVault.id }) {
            vaults[index].isMounted = false
            saveVaults()
        }
        
        // 调用VFS的锁定方法，清除主密钥和重置数据库
        vfs.lock()
        
        isVaultUnlocked = false
        currentVault = nil
        
        // 清除解锁相关的状态，确保可以再次解锁
        showUnlockVault = false
        selectedVaultForUnlock = nil
        
        print("✅ AppState: 保险库已锁定")
    }
    
    /// 删除保险库
    func deleteVault(_ vault: VaultInfo) {
        print("🗑️ AppState: 删除保险库: \(vault.name)")
        
        // 检查是否已挂载
        if vault.isMounted {
            print("⚠️ AppState: 保险库已挂载，无法删除")
            return
        }
        
        // 清理相关资源
        deleteVaultResources(vault: vault)
        
        // 从列表中移除
        vaults.removeAll { $0.id == vault.id }
        saveVaults()
        
        if currentVault?.id == vault.id {
            lockVault()
        }
        
        print("✅ AppState: 保险库已删除")
    }
    
    /// 清理保险库相关资源
    private func deleteVaultResources(vault: VaultInfo) {
        print("🧹 AppState: 清理保险库资源: \(vault.name)")
        
        // 1. 从 Keychain 中删除密码
        deleteWebDAVPassword(for: vault.id)
        
        // 2. 清理共享文件
        cleanupSharedFiles()
        
        // 3. 移除 File Provider Domain
        Task {
            await removeFileProviderDomain(for: vault)
        }
    }
    
    /// 从 Keychain 中删除 WebDAV 密码
    private func deleteWebDAVPassword(for vaultId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "webdav-password-\(vaultId)",
            kSecAttrService as String: "net.aabg.CloudDrive",
            kSecAttrAccessGroup as String: "group.net.aabg.CloudDrive"
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess {
            print("✅ Keychain: 密码删除成功")
        } else if status == errSecItemNotFound {
            print("ℹ️ Keychain: 密码不存在")
        } else {
            print("❌ Keychain: 密码删除失败，状态码: \(status)")
        }
    }
    
    /// 清理共享文件
    private func cleanupSharedFiles() {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.net.aabg.CloudDrive"
        ) else {
            print("❌ AppState: 无法获取 App Group 容器 URL")
            return
        }
        
        let configURL = containerURL.appendingPathComponent("vault_config.json")
        
        do {
            if FileManager.default.fileExists(atPath: configURL.path) {
                try FileManager.default.removeItem(at: configURL)
                print("✅ AppState: 共享配置文件已删除")
            }
        } catch {
            print("❌ AppState: 共享配置文件删除失败: \(error)")
        }
    }
    
    /// 移除 File Provider Domain
    private func removeFileProviderDomain(for vault: VaultInfo) async {
        let domainIdentifier = NSFileProviderDomainIdentifier(rawValue: "vault-\(vault.id)")
        let domain = NSFileProviderDomain(identifier: domainIdentifier, displayName: vault.name)
        
        print("🗑️ AppState: 移除 File Provider Domain: \(domainIdentifier.rawValue)")
        
        do {
            try await NSFileProviderManager.remove(domain)
            print("✅ AppState: File Provider Domain 已移除")
        } catch {
            print("⚠️ AppState: File Provider Domain 移除失败: \(error.localizedDescription)")
        }
    }
    
    /// 卸载保险库
    func unmountVault(_ vault: VaultInfo) {
        print("📤 AppState: 卸载保险库: \(vault.name)")
        
        if let index = vaults.firstIndex(where: { $0.id == vault.id }) {
            vaults[index].isMounted = false
            saveVaults()
        }
        
        if currentVault?.id == vault.id {
            lockVault()
        }
        
        print("✅ AppState: 保险库已卸载")
    }
    
    // MARK: - Persistence
    
    private func loadVaults() {
        if let data = userDefaults.data(forKey: vaultsKey),
           let decoded = try? JSONDecoder().decode([VaultInfo].self, from: data) {
            vaults = decoded
            print("📂 AppState: 加载了 \(vaults.count) 个保险库")
        }
    }
    
    private func saveVaults() {
        if let encoded = try? JSONEncoder().encode(vaults) {
            userDefaults.set(encoded, forKey: vaultsKey)
            print("💾 AppState: 保存了 \(vaults.count) 个保险库")
        }
    }
}
