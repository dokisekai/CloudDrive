//
//  VirtualFileSystem.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  虚拟文件系统 - 类似 Cryptomator 的架构
//  在本地维护文件结构映射，WebDAV 只存储加密数据
//

import Foundation
import CryptoKit

// MARK: - Errors

public enum VFSError: Error, LocalizedError {
    case vaultLocked
    case parentNotFound
    case fileNotFound
    case itemNotFound
    case encryptionFailed
    case decryptionFailed
    case databaseError(String)
    case invalidPath
    case networkError
    case authenticationFailed
    case storageNotConfigured
    case directoryCreationFailed(String)
    case fileOperationFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .vaultLocked:
            return "保险库已锁定"
        case .parentNotFound:
            return "父目录不存在"
        case .fileNotFound:
            return "文件不存在"
        case .itemNotFound:
            return "项目不存在"
        case .encryptionFailed:
            return "加密失败"
        case .decryptionFailed:
            return "解密失败"
        case .databaseError(let detail):
            return "数据库错误: \(detail)"
        case .invalidPath:
            return "无效的路径"
        case .networkError:
            return "网络错误"
        case .authenticationFailed:
            return "认证失败"
        case .storageNotConfigured:
            return "存储未配置"
        case .directoryCreationFailed(let detail):
            return "目录创建失败: \(detail)"
        case .fileOperationFailed(let detail):
            return "文件操作失败: \(detail)"
        }
    }
}

/// 虚拟文件系统管理器
public class VirtualFileSystem {
    public static let shared = VirtualFileSystem()
    
    private var database: VFSDatabase
    private let encryption: VFSEncryption
    private var storageClient: StorageClient?
    
    // 同步管理器
    private let syncManager = SyncManager.shared
    
    // 操作管理器
    private let operationManager = FileOperationManager.shared
    
    // 当前保险库 ID，用于密钥链访问
    private var currentVaultId: String?
    
    // 虚拟根目录 ID
    private let rootId = "ROOT"
    
    private init() {
        self.database = VFSDatabase()
        self.encryption = VFSEncryption()
    }
    
    // MARK: - Storage Configuration
    
    /// 配置 WebDAV 存储
    public func configureWebDAV(baseURL: URL, username: String, password: String) {
        print("⚙️ VFS: 配置 WebDAV 存储")
        print("   URL: \(baseURL)")
        let webdavClient = WebDAVClient.shared
        webdavClient.configure(baseURL: baseURL, username: username, password: password)
        self.storageClient = WebDAVStorageAdapter(webDAVClient: webdavClient)
        
        // 配置同步管理器
        if let storageClient = storageClient {
            syncManager.configure(storageClient: storageClient)
        }
        
        print("✅ VFS: WebDAV 存储配置完成")
    }
    
    /// 获取当前配置的 storageClient
    public func getStorageClient() -> StorageClient? {
        return storageClient
    }
    
    // MARK: - Initialization
    
    /// 初始化保险库（首次使用）
    public func initializeVault(password: String, storagePath: String) async throws -> String {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("🔧 VFS: 初始化保险库")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📂 存储路径: \(storagePath)")
        print("🏠 存储类型: WebDAV")
        
        guard let storageClient = storageClient else {
            print("❌ VFS: storageClient 未配置")
            throw VFSError.storageNotConfigured
        }
        print("✅ VFS: storageClient 已配置")
        
        // 1. 生成主密钥和盐
        print("🔑 VFS: 生成主密钥和盐...")
        let (masterKey, salt) = try encryption.generateMasterKey(password: password)
        print("✅ VFS: 主密钥生成成功")
        print("🧂 VFS: 盐生成成功 (长度: \(salt.count) 字节)")
        
        // 2. 创建加密的保险库结构
        let vaultId = UUID().uuidString
        let vaultPath = "\(storagePath)/\(vaultId)"
        print("📁 VFS: 保险库路径: \(vaultPath)")
        
        // 创建保险库目录结构
        do {
            print("📁 VFS: 创建主目录...")
            try await storageClient.createDirectory(path: vaultPath)
            print("✅ VFS: 主目录创建成功")
            
            print("📁 VFS: 创建 d 目录（存储目录）...")
            try await storageClient.createDirectory(path: "\(vaultPath)/d")
            print("✅ VFS: d 目录创建成功")
            
            print("📁 VFS: 创建 f 目录（存储文件）...")
            try await storageClient.createDirectory(path: "\(vaultPath)/f")
            print("✅ VFS: f 目录创建成功")
            
            // 验证目录是否真的创建成功
            let dExists = try await storageClient.exists(path: "\(vaultPath)/d")
            let fExists = try await storageClient.exists(path: "\(vaultPath)/f")
            print("🔍 VFS: 目录验证 - d: \(dExists ? "✅" : "❌"), f: \(fExists ? "✅" : "❌")")
            
            if !dExists || !fExists {
                throw VFSError.directoryCreationFailed("目录创建后验证失败")
            }
            
        } catch {
            print("❌ VFS: 创建目录失败: \(error)")
            throw VFSError.directoryCreationFailed(error.localizedDescription)
        }
        
        // 3. 创建保险库配置文件
        print("📝 VFS: 创建保险库配置...")
        
        // 将盐以明文形式存储在配置文件中，只加密敏感信息
        let configPath = "\(vaultPath)/vault.cryptomator"
        let saltPath = "\(vaultPath)/salt"
        
        do {
            // 1. 保存盐（明文）- 使用临时文件上传
            let saltData = salt
            let tempDir = FileManager.default.temporaryDirectory
            let tempSaltURL = tempDir.appendingPathComponent("salt_\(UUID().uuidString)")
            
            try saltData.write(to: tempSaltURL, options: [.atomic])
            print("💾 VFS: 写入临时盐文件: \(tempSaltURL.path)")
            
            // 通过 storageClient 上传盐值文件
            try await storageClient.uploadFile(localURL: tempSaltURL, to: saltPath) { _ in }
            
            // 清理临时文件
            try? FileManager.default.removeItem(at: tempSaltURL)
            print("✅ VFS: 盐文件写入成功")
            
            // 2. 创建并保存加密的配置文件 - 使用 storageClient 写入
            let vaultConfig = VaultConfig(
                vaultId: vaultId,
                version: 1,
                cipherCombo: "AES-GCM",
                createdAt: Date(),
                salt: salt
            )
            
            let configData = try JSONEncoder().encode(vaultConfig)
            print("📊 VFS: 配置数据大小: \(configData.count) 字节")
            
            let encryptedConfig = try encryption.encrypt(data: configData, key: masterKey)
            print("🔐 VFS: 配置已加密，大小: \(encryptedConfig.count) 字节")
            
            // 使用临时文件上传（复用上面的 tempDir）
            let tempConfigURL = tempDir.appendingPathComponent("config_\(UUID().uuidString)")
            
            try encryptedConfig.write(to: tempConfigURL, options: [.atomic])
            print("💾 VFS: 写入临时配置文件: \(tempConfigURL.path)")
            
            // 通过 storageClient 上传配置文件
            try await storageClient.uploadFile(localURL: tempConfigURL, to: configPath) { _ in }
            
            // 清理临时文件
            try? FileManager.default.removeItem(at: tempConfigURL)
            print("✅ VFS: 配置文件写入成功")
            
        } catch {
            print("❌ VFS: 配置文件创建失败: \(error)")
            throw VFSError.fileOperationFailed("配置文件创建失败: \(error.localizedDescription)")
        }
        
        // 4. 初始化本地数据库
        print("💾 VFS: 初始化本地数据库...")
        do {
            try database.initialize(vaultId: vaultId, basePath: vaultPath)
            print("✅ VFS: 数据库初始化成功")
        } catch {
            print("❌ VFS: 数据库初始化失败: \(error)")
            print("   错误详情: \(error.localizedDescription)")
            if let nsError = error as NSError? {
                print("   Domain: \(nsError.domain)")
                print("   Code: \(nsError.code)")
                print("   UserInfo: \(nsError.userInfo)")
            }
            throw error
        }
        
        // 5. 创建根目录映射
        print("📁 VFS: 创建根目录映射...")
        do {
            let rootDirId = try encryption.encryptDirectoryId(rootId, key: masterKey)
            print("🔐 VFS: 根目录ID已加密: \(rootDirId)")
            
            try database.insertDirectory(
                id: rootId,
                name: "Root",
                parentId: nil,
                encryptedId: rootDirId,
                remotePath: "\(vaultPath)/d/\(rootDirId)"
            )
            print("✅ VFS: 根目录映射已创建")
        } catch {
            print("❌ VFS: 根目录映射创建失败: \(error)")
            throw VFSError.databaseError("根目录映射创建失败: \(error.localizedDescription)")
        }
        
        // 6. 保存主密钥到内存和密钥链
        encryption.setMasterKey(masterKey)
        try KeychainService.storeMasterKey(masterKey, forVault: vaultId)
        self.currentVaultId = vaultId
        print("🔑 VFS: 主密钥已保存到内存和密钥链")
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("✅ VFS: 保险库初始化完成")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        return vaultId
    }
    
    /// 初始化保险库（无加密模式）
    public func initializeVaultWithoutEncryption(storagePath: String) async throws -> String {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("🔧 VFS: 初始化保险库（无加密模式）")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📂 存储路径: \(storagePath)")
        print("🏠 存储类型: WebDAV")
        
        guard let storageClient = storageClient else {
            print("❌ VFS: storageClient 未配置")
            throw VFSError.storageNotConfigured
        }
        print("✅ VFS: storageClient 已配置")
        
        // 1. 生成保险库 ID
        let vaultId = UUID().uuidString
        let vaultPath = "\(storagePath)/\(vaultId)"
        print("📁 VFS: 保险库路径: \(vaultPath)")
        
        // 2. 创建保险库目录结构
        do {
            print("📁 VFS: 创建主目录...")
            try await storageClient.createDirectory(path: vaultPath)
            print("✅ VFS: 主目录创建成功")
            
            print("📁 VFS: 创建 files 目录（存储文件）...")
            try await storageClient.createDirectory(path: "\(vaultPath)/files")
            print("✅ VFS: files 目录创建成功")
            
            // 验证目录是否真的创建成功
            let filesExists = try await storageClient.exists(path: "\(vaultPath)/files")
            print("🔍 VFS: 目录验证 - files: \(filesExists ? "✅" : "❌")")
            
            if !filesExists {
                throw VFSError.directoryCreationFailed("目录创建后验证失败")
            }
            
        } catch {
            print("❌ VFS: 创建目录失败: \(error)")
            throw VFSError.directoryCreationFailed(error.localizedDescription)
        }
        
        // 3. 创建保险库配置文件（无加密）
        print("📝 VFS: 创建保险库配置...")
        let configPath = "\(vaultPath)/vault.config"
        
        do {
            let vaultConfig = VaultConfigNoEncryption(
                vaultId: vaultId,
                version: 1,
                encrypted: false,
                createdAt: Date()
            )
            
            let configData = try JSONEncoder().encode(vaultConfig)
            print("📊 VFS: 配置数据大小: \(configData.count) 字节")
            
            // 使用临时文件上传
            let tempDir = FileManager.default.temporaryDirectory
            let tempConfigURL = tempDir.appendingPathComponent("config_\(UUID().uuidString)")
            
            try configData.write(to: tempConfigURL, options: [.atomic])
            print("💾 VFS: 写入临时配置文件: \(tempConfigURL.path)")
            
            // 通过 storageClient 上传配置文件
            try await storageClient.uploadFile(localURL: tempConfigURL, to: configPath) { _ in }
            
            // 清理临时文件
            try? FileManager.default.removeItem(at: tempConfigURL)
            print("✅ VFS: 配置文件写入成功")
            
        } catch {
            print("❌ VFS: 配置文件创建失败: \(error)")
            throw VFSError.fileOperationFailed("配置文件创建失败: \(error.localizedDescription)")
        }
        
        // 4. 初始化本地数据库
        print("💾 VFS: 初始化本地数据库...")
        do {
            try database.initialize(vaultId: vaultId, basePath: vaultPath)
            print("✅ VFS: 数据库初始化成功")
        } catch {
            print("❌ VFS: 数据库初始化失败: \(error)")
            throw error
        }
        
        // 5. 创建根目录映射（无加密）
        print("📁 VFS: 创建根目录映射...")
        do {
            try database.insertDirectory(
                id: rootId,
                name: "Root",
                parentId: nil,
                encryptedId: rootId,
                remotePath: "\(vaultPath)/files"
            )
            print("✅ VFS: 根目录映射已创建")
        } catch {
            print("❌ VFS: 根目录映射创建失败: \(error)")
            throw VFSError.databaseError("根目录映射创建失败: \(error.localizedDescription)")
        }
        
        // 6. 保存保险库 ID
        self.currentVaultId = vaultId
        print("🔑 VFS: 保险库 ID 已保存")
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("✅ VFS: 保险库初始化完成（无加密模式）")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        return vaultId
    }
    
    /// 初始化直接映射保险库（不创建任何远程目录）
    public func initializeDirectMappingVault(vaultId: String, storagePath: String) async throws {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("🔗 VFS: 初始化直接映射保险库")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📂 保险库ID: \(vaultId)")
        print("📂 存储路径: \(storagePath)")
        
        guard let storageClient = storageClient else {
            print("❌ VFS: storageClient 未配置")
            throw VFSError.storageNotConfigured
        }
        print("✅ VFS: storageClient 已配置")
        
        // 1. 初始化本地数据库
        print("💾 VFS: 初始化本地数据库...")
        do {
            try database.initialize(vaultId: vaultId, basePath: storagePath)
            print("✅ VFS: 数据库初始化成功")
        } catch {
            print("❌ VFS: 数据库初始化失败: \(error)")
            throw error
        }
        
        // 2. 创建根目录映射（直接映射到 WebDAV 根目录）
        // 检查根目录是否已存在
        print("📁 VFS: 检查根目录映射...")
        if let existingRoot = try? database.getDirectory(id: rootId) {
            print("✅ VFS: 根目录映射已存在，跳过创建")
            print("   现有路径: \(existingRoot.remotePath)")
        } else {
            print("📁 VFS: 创建根目录映射...")
            do {
                try database.insertDirectory(
                    id: rootId,
                    name: "Root",
                    parentId: nil,
                    encryptedId: rootId,
                    remotePath: storagePath  // 直接映射到根路径
                )
                print("✅ VFS: 根目录映射已创建")
            } catch {
                print("❌ VFS: 根目录映射创建失败: \(error)")
                throw VFSError.databaseError("根目录映射创建失败: \(error.localizedDescription)")
            }
        }
        
        // 3. 保存保险库 ID
        self.currentVaultId = vaultId
        print("🔑 VFS: 保险库 ID 已保存")
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("✅ VFS: 直接映射保险库初始化完成")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    }
    
    /// 检查当前保险库是否已挂载
    public func isVaultMounted(vaultId: String) -> Bool {
        return currentVaultId == vaultId
    }
    
    /// 重新挂载直接映射保险库（不需要配置文件）
    public func remountDirectMappingVault(vaultId: String, storagePath: String) async throws {
        print("🔓 VFS: 重新挂载直接映射保险库")
        print("   保险库ID: \(vaultId)")
        print("   存储路径: \(storagePath)")
        
        // 检查 WebDAV 配置
        guard let storageClient = storageClient else {
            throw VFSError.storageNotConfigured
        }
        print("✅ VFS: storageClient 已配置")
        
        // 检查是否已经是同一个保险库
        if let currentVaultId = currentVaultId, currentVaultId == vaultId {
            print("✅ VFS: 已经挂载了同一个保险库，跳过")
            return
        }
        
        // 如果挂载了其他保险库，先锁定
        if currentVaultId != nil {
            print("⚠️ VFS: 检测到已挂载其他保险库，先锁定")
            lock()
        }
        
        // 加载数据库
        print("💾 VFS: 加载数据库...")
        do {
            try database.load(vaultId: vaultId, basePath: storagePath)
            print("✅ VFS: 数据库加载成功")
        } catch {
            print("❌ VFS: 数据库加载失败: \(error)")
            
            // 如果数据库加载失败，尝试重新初始化（可能数据库文件被删除）
            print("🔄 VFS: 尝试重新初始化数据库...")
            try await initializeDirectMappingVault(vaultId: vaultId, storagePath: storagePath)
            print("✅ VFS: 数据库重新初始化成功")
        }
        
        // 保存保险库 ID
        self.currentVaultId = vaultId
        print("✅ VFS: 直接映射保险库重新挂载成功")
    }
    
    /// 挂载保险库（无加密模式）
    public func mountVaultWithoutEncryption(storagePath: String, vaultId: String) async throws {
        print("🔓 VFS: 挂载保险库（无加密模式）")
        print("   保险库ID: \(vaultId)")
        print("   存储路径: \(storagePath)")
        
        guard let storageClient = storageClient else {
            throw VFSError.storageNotConfigured
        }
        
        // 检查是否已经是同一个保险库
        if let currentVaultId = currentVaultId, currentVaultId == vaultId {
            print("✅ VFS: 已经挂载了同一个保险库，跳过")
            return
        }
        
        // 如果挂载了其他保险库，先锁定
        if currentVaultId != nil {
            print("⚠️ VFS: 检测到已挂载其他保险库，先锁定")
            lock()
        }
        
        // 1. 读取配置文件
        let configPath = "\(storagePath)/\(vaultId)/vault.config"
        
        do {
            print("📥 VFS: 读取配置文件...")
            let tempDir = FileManager.default.temporaryDirectory
            let tempConfigURL = tempDir.appendingPathComponent("config_\(UUID().uuidString)")
            
            try await storageClient.downloadFile(path: configPath, to: tempConfigURL) { _ in }
            let configData = try Data(contentsOf: tempConfigURL)
            
            // 清理临时文件
            try? FileManager.default.removeItem(at: tempConfigURL)
            
            let vaultConfig = try JSONDecoder().decode(VaultConfigNoEncryption.self, from: configData)
            print("✅ VFS: 配置文件读取成功")
            
            // 2. 加载本地数据库
            print("💾 VFS: 加载数据库...")
            try database.load(vaultId: vaultConfig.vaultId, basePath: "\(storagePath)/\(vaultId)")
            print("✅ VFS: 数据库加载成功")
            
            // 3. 保存保险库 ID
            self.currentVaultId = vaultConfig.vaultId
            print("✅ VFS: 保险库挂载成功（无加密模式）")
            
        } catch {
            print("❌ VFS: 挂载失败: \(error)")
            throw error
        }
    }
    
    /// 解锁保险库
    /// 锁定保险库（清除主密钥和关闭数据库）
    public func lock() {
        print("🔒 VFS: 锁定保险库...")
        
        // 从密钥链删除主密钥
        if let vaultId = currentVaultId {
            try? KeychainService.deleteMasterKey(forVault: vaultId)
            currentVaultId = nil
        }
        
        // 清除内存中的主密钥
        encryption.setMasterKey(SymmetricKey(data: Data()))
        print("✅ VFS: 主密钥已清除")
        
        // 关闭数据库（通过deinit自动调用，但显式调用更安全）
        database = VFSDatabase()
        print("✅ VFS: 数据库已重置")
    }
    
    public func unlockVault(password: String, storagePath: String, vaultId: String) async throws {
        print("🔓 VFS: 解锁保险库")
        print("   保险库ID: \(vaultId)")
        print("   存储路径: \(storagePath)")
        
        guard let storageClient = storageClient else {
            throw VFSError.storageNotConfigured
        }
        
        // 1. 读取盐文件和配置文件
        let configPath = "\(storagePath)/\(vaultId)/vault.cryptomator"
        let saltPath = "\(storagePath)/\(vaultId)/salt"
        
        var masterKey: SymmetricKey! = nil
        var vaultConfig: VaultConfig! = nil
        
        do {
            // 1. 读取盐文件（明文）
            print("📥 VFS: 读取盐文件...")
            let tempDir = FileManager.default.temporaryDirectory
            let tempSaltURL = tempDir.appendingPathComponent("salt_\(UUID().uuidString)")
            
            try await storageClient.downloadFile(path: saltPath, to: tempSaltURL) { _ in }
            let salt = try Data(contentsOf: tempSaltURL)
            
            // 清理临时文件
            try? FileManager.default.removeItem(at: tempSaltURL)
            
            print("✅ VFS: 盐文件读取成功，大小: \(salt.count) 字节")
            
            // 2. 读取配置文件
            print("📥 VFS: 读取配置文件...")
            let tempConfigURL = tempDir.appendingPathComponent("config_\(UUID().uuidString)")
            
            try await storageClient.downloadFile(path: configPath, to: tempConfigURL) { _ in }
            let encryptedConfig = try Data(contentsOf: tempConfigURL)
            
            // 清理临时文件
            try? FileManager.default.removeItem(at: tempConfigURL)
            
            print("✅ VFS: 配置文件读取成功，大小: \(encryptedConfig.count) 字节")
            
            // 3. 使用盐派生主密钥
            print("🔑 VFS: 派生主密钥...")
            masterKey = try encryption.deriveMasterKey(password: password, salt: salt)
            print("✅ VFS: 主密钥派生成功")
            
            // 4. 解密配置
            print("🔓 VFS: 解密配置...")
            let configData = try encryption.decrypt(data: encryptedConfig, key: masterKey)
            vaultConfig = try JSONDecoder().decode(VaultConfig.self, from: configData)
            print("✅ VFS: 配置解密成功")
            
        } catch {
            print("❌ VFS: 解锁失败: \(error)")
            throw error
        }
        
        // 4. 加载本地数据库
        print("💾 VFS: 加载数据库...")
        try database.load(vaultId: vaultConfig.vaultId, basePath: "\(storagePath)/\(vaultId)")
        print("✅ VFS: 数据库加载成功")
        
        // 5. 保存主密钥到内存和密钥链
        encryption.setMasterKey(masterKey)
        try KeychainService.storeMasterKey(masterKey, forVault: vaultConfig.vaultId)
        self.currentVaultId = vaultConfig.vaultId
        print("✅ VFS: 保险库解锁成功")
    }
    
    // MARK: - Sync Operations
    
    /// 获取网络状态
    public func getNetworkStatus() -> NetworkStatus {
        return syncManager.getNetworkStatus()
    }
    
    /// 同步目录（比较本地和云端）
    public func syncDirectory(directoryId: String, localPath: String, remotePath: String) async throws -> [FileMetadata] {
        return try await syncManager.syncDirectory(directoryId: directoryId, localPath: localPath, remotePath: remotePath)
    }
    
    /// 获取待同步文件数量
    public func getPendingSyncCount() -> Int {
        return syncManager.getSyncQueueCount()
    }
    
    /// 手动触发同步队列处理
    public func processSyncQueue() {
        syncManager.processSyncQueue()
    }
    
    // MARK: - File Operations
    
    /// 列出目录内容（带同步状态检测）
    public func listDirectory(directoryId: String) throws -> [VirtualFileItem] {
        print("📂 VFS: listDirectory 被调用 - directoryId: \(directoryId)")
        print("   storageClient: \(storageClient != nil ? "已配置" : "未配置")")
        print("   currentVaultId: \(currentVaultId ?? "nil")")
        
        // 如果是直接映射模式，从 WebDAV 服务器获取文件列表
        if let storageClient = storageClient, currentVaultId != nil {
            print("✅ VFS: 使用 WebDAV 直接获取文件列表")
            // 尝试从 WebDAV 直接获取
            return try listDirectoryFromWebDAV(directoryId: directoryId)
        }
        
        // 否则从数据库获取
        do {
            return try database.listChildren(parentId: directoryId)
        } catch VFSError.databaseError(let message) {
            // 如果数据库未打开或保险库未解锁，尝试从 WebDAV 获取
            print("⚠️ VFS: 数据库未准备好，尝试从 WebDAV 获取: \(message)")
            if let storageClient = storageClient {
                return try listDirectoryFromWebDAV(directoryId: directoryId)
            }
            return []
        } catch {
            // 其他错误继续抛出
            throw error
        }
    }
    
    /// 从 WebDAV 直接列出目录内容（完全透明映射）
    private func listDirectoryFromWebDAV(directoryId: String) throws -> [VirtualFileItem] {
        guard let storageClient = storageClient else {
            print("❌ VFS: 存储客户端未配置")
            return []
        }
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📡 VFS.listDirectoryFromWebDAV: 开始")
        print("   目录ID: \(directoryId)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        // 直接使用目录ID作为WebDAV路径
        // 如果是ROOT，使用"/"，否则directoryId就是完整路径
        let remotePath: String
        if directoryId == "ROOT" {
            remotePath = "/"
        } else {
            // directoryId 就是 WebDAV 路径
            remotePath = directoryId
        }
        
        print("📂 VFS: WebDAV 路径: \(remotePath)")
        
        // 使用同步方式获取（因为这个方法是同步的）
        var resources: [StorageResource] = []
        let semaphore = DispatchSemaphore(value: 0)
        var fetchError: Error?
        
        Task {
            do {
                resources = try await storageClient.listDirectory(path: remotePath)
                print("✅ VFS: 获取到 \(resources.count) 个项目")
                for resource in resources {
                    print("   - \(resource.isDirectory ? "📁" : "📄") \(resource.displayName)")
                }
            } catch {
                print("❌ VFS: 获取目录列表失败: \(error)")
                fetchError = error
            }
            semaphore.signal()
        }
        
        semaphore.wait()
        
        if let error = fetchError {
            throw error
        }
        
        // 转换为 VirtualFileItem
        // 关键：使用完整的 WebDAV 路径作为 ID
        let items = resources.map { resource -> VirtualFileItem in
            // 构建完整路径作为 ID
            let fullPath: String
            if remotePath == "/" {
                fullPath = "/\(resource.displayName)"
            } else if remotePath.hasSuffix("/") {
                fullPath = "\(remotePath)\(resource.displayName)"
            } else {
                fullPath = "\(remotePath)/\(resource.displayName)"
            }
            
            print("   映射: \(resource.displayName) -> ID: \(fullPath)")
            
            return VirtualFileItem(
                id: fullPath,  // ✅ 使用完整 WebDAV 路径作为 ID
                name: resource.displayName,
                isDirectory: resource.isDirectory,
                size: resource.contentLength,
                modifiedAt: resource.lastModified ?? Date(),
                parentId: directoryId
            )
        }
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("✅ VFS.listDirectoryFromWebDAV: 完成")
        print("   返回 \(items.count) 个项目")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        return items
    }
    
    /// 从 WebDAV 异步获取目录内容（强制刷新，不使用缓存）
    public func listDirectoryFromWebDAVAsync(directoryId: String) async throws -> [VirtualFileItem] {
        guard let storageClient = storageClient else {
            print("❌ VFS: 存储客户端未配置")
            throw VFSError.storageNotConfigured
        }
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📡 VFS.listDirectoryFromWebDAVAsync: 强制从云端获取最新数据")
        print("   目录ID: \(directoryId)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        // 直接使用目录ID作为WebDAV路径
        let remotePath: String
        if directoryId == "ROOT" {
            remotePath = "/"
        } else {
            remotePath = directoryId
        }
        
        print("📂 VFS: WebDAV 路径: \(remotePath)")
        print("🔄 VFS: 强制刷新，忽略所有缓存")
        
        do {
            // 直接从 WebDAV 服务器获取最新数据
            let resources = try await storageClient.listDirectory(path: remotePath)
            print("✅ VFS: 从云端获取到 \(resources.count) 个最新项目")
            
            for resource in resources {
                print("   - \(resource.isDirectory ? "📁" : "📄") \(resource.displayName) (修改时间: \(resource.lastModified?.description ?? "未知"))")
            }
            
            // 转换为 VirtualFileItem
            let items = resources.map { resource -> VirtualFileItem in
                let fullPath: String
                if remotePath == "/" {
                    fullPath = "/\(resource.displayName)"
                } else if remotePath.hasSuffix("/") {
                    fullPath = "\(remotePath)\(resource.displayName)"
                } else {
                    fullPath = "\(remotePath)/\(resource.displayName)"
                }
                
                print("   映射: \(resource.displayName) -> ID: \(fullPath)")
                
                return VirtualFileItem(
                    id: fullPath,
                    name: resource.displayName,
                    isDirectory: resource.isDirectory,
                    size: resource.contentLength,
                    modifiedAt: resource.lastModified ?? Date(),
                    parentId: directoryId
                )
            }
            
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("✅ VFS.listDirectoryFromWebDAVAsync: 完成")
            print("   返回 \(items.count) 个最新项目")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                        return items
            
        } catch {
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("❌ VFS.listDirectoryFromWebDAVAsync: 获取失败")
            print("   目录ID: \(directoryId)")
            print("   WebDAV路径: \(remotePath)")
            print("   错误: \(error)")
            print("   错误类型: \(type(of: error))")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            throw error
        }
    }
    
    /// 创建目录（支持直接映射模式）
    public func createDirectory(name: String, parentId: String) async throws -> VirtualFileItem {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📁 VFS.createDirectory: 开始创建目录")
        print("   目录名: \(name)")
        print("   父目录ID: \(parentId)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        guard let storageClient = storageClient else {
            print("❌ VFS: 存储未配置")
            throw VFSError.storageNotConfigured
        }
        
        // 1. 确定远程路径（支持直接映射模式）
        let remotePath: String
        
        // 尝试从数据库获取父目录
        if let parent = try? database.getDirectory(id: parentId) {
            // 数据库模式：使用数据库中的路径
            remotePath = "\(parent.remotePath)/\(name)"
            print("📂 VFS: 使用数据库模式")
            print("   父目录路径: \(parent.remotePath)")
        } else {
            // 直接映射模式：parentId 就是 WebDAV 路径
            print("📂 VFS: 使用直接映射模式")
            if parentId == "ROOT" {
                remotePath = "/\(name)"
            } else if parentId.hasSuffix("/") {
                remotePath = "\(parentId)\(name)"
            } else {
                remotePath = "\(parentId)/\(name)"
            }
            print("   父目录路径: \(parentId)")
        }
        
        print("📄 VFS: 远程目录路径: \(remotePath)")
        
        let operationId = operationManager.addOperation(
            type: .create,
            fileName: name,
            filePath: remotePath
        )
        
        // 2. 在 WebDAV 上创建目录
        print("⬆️ VFS: 在远程存储创建目录...")
        do {
            operationManager.updateOperation(id: operationId, status: .inProgress)
            try await storageClient.createDirectory(path: remotePath)
            print("✅ VFS: 远程目录创建成功")
        } catch {
            operationManager.updateOperation(id: operationId, status: .failed, errorMessage: error.localizedDescription)
            print("❌ VFS: 远程目录创建失败: \(error)")
            throw VFSError.directoryCreationFailed(error.localizedDescription)
        }
        
        // 3. 生成目录 ID（使用完整路径作为 ID，保持一致性）
        let dirId = remotePath
        print("🆔 VFS: 目录ID: \(dirId)")
        
        // 4. 尝试保存到数据库（如果数据库可用）
        do {
            try database.insertDirectory(
                id: dirId,
                name: name,
                parentId: parentId,
                encryptedId: name,
                remotePath: remotePath
            )
            print("✅ VFS: 数据库记录已保存")
        } catch {
            print("⚠️ VFS: 数据库保存失败（直接映射模式下可忽略）: \(error)")
            // 直接映射模式下，数据库保存失败不影响操作
        }
        
        // 5. 更新同步状态
        print("🔄 VFS: 更新同步状态...")
        let metadata = FileMetadata(
            fileId: dirId,
            name: name,
            parentId: parentId,
            isDirectory: true,
            syncStatus: .synced,
            remotePath: remotePath,
            localModifiedAt: Date(),
            remoteModifiedAt: Date()
        )
        syncManager.updateMetadata(metadata)
        print("✅ VFS: 同步状态已更新")
        
        operationManager.updateOperation(id: operationId, status: .completed)
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("✅ VFS.createDirectory: 目录创建完成")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        return VirtualFileItem(
            id: dirId,
            name: name,
            isDirectory: true,
            size: 0,
            modifiedAt: Date(),
            parentId: parentId,
            syncStatus: .synced,
            remotePath: remotePath
        )
    }
    
    /// 上传文件（支持直接映射模式）
    public func uploadFile(localURL: URL, name: String, parentId: String) async throws -> VirtualFileItem {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("⬆️ VFS.uploadFile: 开始上传文件")
        print("   文件名: \(name)")
        print("   父目录ID: \(parentId)")
        print("   本地路径: \(localURL.path)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        guard let storageClient = storageClient else {
            print("❌ VFS: 存储未配置")
            throw VFSError.storageNotConfigured
        }
        
        // 1. 读取文件内容
        print("📖 VFS: 读取文件内容...")
        let fileData = try Data(contentsOf: localURL)
        print("📊 VFS: 文件大小: \(fileData.count) 字节")
        
        // 2. 确定远程路径（支持直接映射模式）
        let remoteFilePath: String
        
        // 尝试从数据库获取父目录
        if let parent = try? database.getDirectory(id: parentId) {
            // 数据库模式：使用数据库中的路径
            remoteFilePath = "\(parent.remotePath)/\(name)"
            print("📂 VFS: 使用数据库模式")
            print("   父目录路径: \(parent.remotePath)")
        } else {
            // 直接映射模式：parentId 就是 WebDAV 路径
            print("📂 VFS: 使用直接映射模式")
            if parentId == "ROOT" {
                remoteFilePath = "/\(name)"
            } else if parentId.hasSuffix("/") {
                remoteFilePath = "\(parentId)\(name)"
            } else {
                remoteFilePath = "\(parentId)/\(name)"
            }
            print("   父目录路径: \(parentId)")
        }
        
        print("📄 VFS: 远程文件路径: \(remoteFilePath)")
        
        let operationId = operationManager.addOperation(
            type: .upload,
            fileName: name,
            filePath: remoteFilePath
        )
        
        // 3. 上传文件到 WebDAV
        print("⬆️ VFS: 上传文件到远程存储...")
        do {
            try await storageClient.uploadFile(localURL: localURL, to: remoteFilePath) { [self] progress in
                if Int(progress * 100) % 20 == 0 {  // 每20%打印一次
                    print("📊 VFS: 上传进度: \(Int(progress * 100))%")
                }
                self.operationManager.updateProgress(id: operationId, progress: progress)
            }
            print("✅ VFS: 文件上传成功")
        } catch {
            operationManager.updateOperation(id: operationId, status: .failed, errorMessage: error.localizedDescription)
            print("❌ VFS: 文件上传失败: \(error)")
            throw VFSError.fileOperationFailed("上传失败: \(error.localizedDescription)")
        }
        
        // 4. 生成文件 ID（使用完整路径作为 ID，保持一致性）
        let fileId = remoteFilePath
        print("🆔 VFS: 文件ID: \(fileId)")
        
        // 5. 尝试保存到数据库（如果数据库可用）
        do {
            try database.insertFile(
                id: fileId,
                name: name,
                parentId: parentId,
                size: Int64(fileData.count),
                encryptedName: name,
                remotePath: remoteFilePath
            )
            print("✅ VFS: 数据库记录已保存")
        } catch {
            print("⚠️ VFS: 数据库保存失败（直接映射模式下可忽略）: \(error)")
            // 直接映射模式下，数据库保存失败不影响操作
        }
        
        // 6. 更新同步状态
        print("🔄 VFS: 更新同步状态...")
        let metadata = FileMetadata(
            fileId: fileId,
            name: name,
            parentId: parentId,
            isDirectory: false,
            syncStatus: .synced,
            localPath: localURL.path,
            remotePath: remoteFilePath,
            size: Int64(fileData.count),
            localModifiedAt: Date(),
            remoteModifiedAt: Date()
        )
        syncManager.updateMetadata(metadata)
        print("✅ VFS: 同步状态已更新")
        
        operationManager.updateOperation(id: operationId, status: .completed)
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("✅ VFS.uploadFile: 文件上传完成")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        return VirtualFileItem(
            id: fileId,
            name: name,
            isDirectory: false,
            size: Int64(fileData.count),
            modifiedAt: Date(),
            parentId: parentId,
            syncStatus: .synced,
            localPath: localURL.path,
            remotePath: remoteFilePath
        )
    }
    
    /// 下载文件（完全透明映射 - fileId 就是 WebDAV 路径）
    public func downloadFile(fileId: String, to destinationURL: URL) async throws {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("⬇️ VFS.downloadFile: 开始下载（直接映射模式）")
        print("   文件ID（WebDAV路径）: \(fileId)")
        print("   目标路径: \(destinationURL.path)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        // 使用错误桥接器确保错误域兼容性
        do {
            try await VFSErrorBridge.executeAsync {
                guard let storageClient = self.storageClient else {
                    print("❌ VFS: 存储未配置")
                    throw VFSError.storageNotConfigured
                }
                print("✅ VFS: storageClient 已配置")
                
                // 直接使用 fileId 作为 WebDAV 路径
                // fileId 已经是完整的 WebDAV 路径（如 "/folder/file.txt"）
                let webdavPath = fileId
                
                print("📡 VFS: 直接下载")
                print("   WebDAV 路径: \(webdavPath)")
                print("   调用: storageClient.downloadFile(path: \(webdavPath))")
                
                try await storageClient.downloadFile(path: webdavPath, to: destinationURL) { progress in
                    if Int(progress * 100) % 20 == 0 {  // 每20%打印一次
                        print("📊 VFS: 下载进度: \(Int(progress * 100))%")
                    }
                }
                
                print("✅ VFS: 文件下载完成")
            }
        } catch {
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("❌ VFS.downloadFile: 下载失败")
            print("   文件ID: \(fileId)")
            print("   错误: \(error)")
            print("   错误类型: \(type(of: error))")
            
            if let webdavError = error as? WebDAVError,
               case .serverError(let statusCode) = webdavError {
                print("   HTTP 状态码: \(statusCode)")
                if statusCode == 404 {
                    print("   🔴 404 Not Found - 文件不存在")
                    print("   请检查:")
                    print("   1. WebDAV 路径是否正确: \(fileId)")
                    print("   2. 文件是否真的存在于服务器")
                    print("   3. URL 编码是否正确")
                }
            }
            
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            throw error
        }
    }
    
    /// 删除文件或目录（支持直接映射模式）
    public func delete(itemId: String) async throws {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("🗑️ VFS.delete: 开始删除云端文件")
        print("   项目ID: \(itemId)")
        print("   当前时间: \(Date())")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        // 使用错误桥接器确保错误域兼容性
        do {
            try await VFSErrorBridge.executeAsync {
                print("🔄 VFS: 进入错误桥接器")
                
                guard let storageClient = self.storageClient else {
                    print("❌ VFS: 存储未配置")
                    throw VFSError.storageNotConfigured
                }
                print("✅ VFS: storageClient 已配置")
                
                // 1. 尝试从数据库获取文件信息
                print("🔍 VFS: 尝试从数据库获取文件...")
                if let file = try? self.database.getFile(id: itemId) {
                    print("✅ VFS: 找到文件（数据库模式）: \(file.name)")
                    print("   远程路径: \(file.remotePath)")
                    print("📤 VFS: 调用 storageClient.delete(path: \(file.remotePath))")
                    
                    let fileName = URL(fileURLWithPath: itemId).lastPathComponent
                    let operationId = operationManager.addOperation(
                        type: .delete,
                        fileName: fileName,
                        filePath: file.remotePath
                    )
                    
                    operationManager.updateOperation(id: operationId, status: .inProgress)
                    
                    // 删除远程文件
                    try await storageClient.delete(path: file.remotePath)
                    print("✅ VFS: 远程文件删除成功")
                    
                    // 删除数据库记录
                    try self.database.deleteFile(id: itemId)
                    print("✅ VFS: 数据库记录删除成功")
                    
                    // 更新同步状态（删除元数据）
                    print("🔄 VFS: 删除同步元数据...")
                    self.syncManager.removeMetadata(fileId: itemId)
                    print("✅ VFS: 同步元数据已删除")
                    
                    operationManager.updateOperation(id: operationId, status: .completed)
                    
                    print("✅ VFS: 文件删除成功（数据库模式）")
                    return
                }
                
                print("🔍 VFS: 尝试从数据库获取目录...")
                if let directory = try? self.database.getDirectory(id: itemId) {
                    print("✅ VFS: 找到目录（数据库模式）: \(directory.name)")
                    print("   远程路径: \(directory.remotePath)")
                    print("📤 VFS: 直接删除远程目录")
                    
                    // 直接删除远程目录（不递归）
                    try await storageClient.delete(path: directory.remotePath)
                    print("✅ VFS: 远程目录删除成功")
                    
                    // 删除数据库记录
                    try self.database.deleteDirectory(id: itemId)
                    print("✅ VFS: 数据库记录删除成功")
                    
                    // 更新同步状态（删除元数据）
                    print("🔄 VFS: 删除同步元数据...")
                    self.syncManager.removeMetadata(fileId: itemId)
                    print("✅ VFS: 同步元数据已删除")
                    
                    print("✅ VFS: 目录删除成功（数据库模式）")
                    return
                }
                
                // 2. 数据库中没有找到，尝试直接映射模式
                print("⚠️ VFS: 数据库中未找到项目，尝试直接映射模式")
                print("📂 VFS: 使用 itemId 作为 WebDAV 路径: \(itemId)")
                
                // 在直接映射模式下，itemId 就是 WebDAV 路径
                let remotePath = itemId
                
                // 尝试删除（WebDAV 会自动处理文件和目录）
                print("🗑️ VFS: 直接删除远程路径: \(remotePath)")
                print("📤 VFS: 调用 storageClient.delete(path: \(remotePath))")
                
                try await storageClient.delete(path: remotePath)
                print("✅ VFS: 远程删除成功（直接映射模式）")
                
                // 更新同步状态（删除元数据）
                print("🔄 VFS: 删除同步元数据...")
                self.syncManager.removeMetadata(fileId: itemId)
                print("✅ VFS: 同步元数据已删除")
                
                print("✅ VFS: 项目删除成功（直接映射模式）")
            }
            
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("✅ VFS.delete: 删除完成")
            print("   完成时间: \(Date())")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            
        } catch {
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("❌ VFS.delete: 捕获到错误")
            print("   项目ID: \(itemId)")
            print("   错误: \(error)")
            print("   错误类型: \(type(of: error))")
            print("   错误域: \((error as NSError).domain)")
            print("   错误码: \((error as NSError).code)")
            print("   错误时间: \(Date())")
            
            // 检查是否是WebDAV错误
            if let webdavError = error as? WebDAVError {
                print("   WebDAV错误详情: \(webdavError)")
                switch webdavError {
                case .serverError(let statusCode):
                    print("   HTTP状态码: \(statusCode)")
                    if statusCode == 404 {
                        print("   🔍 404错误 - 文件可能已经不存在")
                    } else if statusCode >= 500 {
                        print("   🔍 服务器错误 - 可能是临时问题")
                    }
                default:
                    break
                }
            }
            
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            throw error
        }
    }
    
    /// 修改文件（重新上传）
    public func modifyFile(fileId: String, newContent: URL) async throws -> VirtualFileItem {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("✏️ VFS.modifyFile: 开始修改文件")
        print("   文件ID: \(fileId)")
        print("   新内容路径: \(newContent.path)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        guard let storageClient = storageClient else {
            print("❌ VFS: 存储未配置")
            throw VFSError.storageNotConfigured
        }
        
        // 1. 读取新文件内容
        print("📖 VFS: 读取新文件内容...")
        let fileData = try Data(contentsOf: newContent)
        print("📊 VFS: 文件大小: \(fileData.count) 字节")
        
        // 2. 确定远程路径
        let remotePath: String
        let fileName: String
        let parentId: String
        
        // 尝试从数据库获取文件信息
        if let file = try? database.getFile(id: fileId) {
            // 数据库模式
            remotePath = file.remotePath
            fileName = file.name
            parentId = file.parentId
            print("📂 VFS: 使用数据库模式")
            print("   远程路径: \(remotePath)")
        } else {
            // 直接映射模式：fileId 就是 WebDAV 路径
            remotePath = fileId
            fileName = URL(fileURLWithPath: fileId).lastPathComponent
            parentId = URL(fileURLWithPath: fileId).deletingLastPathComponent().path
            print("📂 VFS: 使用直接映射模式")
            print("   远程路径: \(remotePath)")
        }
        
        // 3. 上传新文件（覆盖）
        print("⬆️ VFS: 上传新文件到远程存储...")
        do {
            try await storageClient.uploadFile(localURL: newContent, to: remotePath) { progress in
                if Int(progress * 100) % 20 == 0 {
                    print("📊 VFS: 上传进度: \(Int(progress * 100))%")
                }
            }
            print("✅ VFS: 文件上传成功")
        } catch {
            print("❌ VFS: 文件上传失败: \(error)")
            throw VFSError.fileOperationFailed("修改失败: \(error.localizedDescription)")
        }
        
        // 4. 更新数据库（如果可用）- 直接映射模式下跳过
        print("ℹ️ VFS: 跳过数据库更新（直接映射模式）")
        
        // 5. 更新同步状态
        print("🔄 VFS: 更新同步状态...")
        let metadata = FileMetadata(
            fileId: fileId,
            name: fileName,
            parentId: parentId,
            isDirectory: false,
            syncStatus: .synced,
            localPath: newContent.path,
            remotePath: remotePath,
            size: Int64(fileData.count),
            localModifiedAt: Date(),
            remoteModifiedAt: Date()
        )
        syncManager.updateMetadata(metadata)
        print("✅ VFS: 同步状态已更新")
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("✅ VFS.modifyFile: 文件修改完成")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        return VirtualFileItem(
            id: fileId,
            name: fileName,
            isDirectory: false,
            size: Int64(fileData.count),
            modifiedAt: Date(),
            parentId: parentId,
            syncStatus: .synced,
            localPath: newContent.path,
            remotePath: remotePath
        )
    }
    
    /// 移动文件或目录
    public func moveItem(itemId: String, newParentId: String, newName: String? = nil) async throws -> VirtualFileItem {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📦 VFS.moveItem: 开始移动项目")
        print("   项目ID: \(itemId)")
        print("   新父目录ID: \(newParentId)")
        print("   新名称: \(newName ?? "保持不变")")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        guard let storageClient = storageClient else {
            print("❌ VFS: 存储未配置")
            throw VFSError.storageNotConfigured
        }
        
        // 1. 确定源路径和目标路径
        let sourcePath: String
        let itemName: String
        let isDirectory: Bool
        
        // 尝试从数据库获取项目信息
        if let file = try? database.getFile(id: itemId) {
            sourcePath = file.remotePath
            itemName = newName ?? file.name
            isDirectory = false
            print("📄 VFS: 找到文件（数据库模式）: \(file.name)")
        } else if let directory = try? database.getDirectory(id: itemId) {
            sourcePath = directory.remotePath
            itemName = newName ?? directory.name
            isDirectory = true
            print("📁 VFS: 找到目录（数据库模式）: \(directory.name)")
        } else {
            // 直接映射模式
            sourcePath = itemId
            itemName = newName ?? URL(fileURLWithPath: itemId).lastPathComponent
            // 无法确定是否为目录，假设为文件
            isDirectory = false
            print("📂 VFS: 使用直接映射模式")
        }
        
        // 2. 确定目标路径
        let destinationPath: String
        if let parent = try? database.getDirectory(id: newParentId) {
            destinationPath = "\(parent.remotePath)/\(itemName)"
            print("📂 VFS: 目标路径（数据库模式）: \(destinationPath)")
        } else {
            // 直接映射模式
            if newParentId == "ROOT" {
                destinationPath = "/\(itemName)"
            } else if newParentId.hasSuffix("/") {
                destinationPath = "\(newParentId)\(itemName)"
            } else {
                destinationPath = "\(newParentId)/\(itemName)"
            }
            print("📂 VFS: 目标路径（直接映射模式）: \(destinationPath)")
        }
        
        let operationId = operationManager.addOperation(
            type: .move,
            fileName: itemName,
            filePath: destinationPath
        )
        
        // 3. 在 WebDAV 上移动
        print("📦 VFS: 移动远程文件...")
        print("   源: \(sourcePath)")
        print("   目标: \(destinationPath)")
        
        do {
            operationManager.updateOperation(id: operationId, status: .inProgress)
            try await storageClient.move(from: sourcePath, to: destinationPath)
            print("✅ VFS: 远程移动成功")
        } catch {
            operationManager.updateOperation(id: operationId, status: .failed, errorMessage: error.localizedDescription)
            print("❌ VFS: 远程移动失败: \(error)")
            throw VFSError.fileOperationFailed("移动失败: \(error.localizedDescription)")
        }
        
        // 4. 更新数据库（如果可用）- 直接映射模式下跳过
        print("ℹ️ VFS: 跳过数据库更新（直接映射模式）")
        
        // 5. 更新同步状态
        print("🔄 VFS: 更新同步状态...")
        // 删除旧的元数据
        syncManager.removeMetadata(fileId: itemId)
        // 添加新的元数据（使用新路径作为 ID）
        let newFileId = destinationPath
        let metadata = FileMetadata(
            fileId: newFileId,
            name: itemName,
            parentId: newParentId,
            isDirectory: isDirectory,
            syncStatus: .synced,
            remotePath: destinationPath,
            localModifiedAt: Date(),
            remoteModifiedAt: Date()
        )
        syncManager.updateMetadata(metadata)
        print("✅ VFS: 同步状态已更新")
        
        operationManager.updateOperation(id: operationId, status: .completed)
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("✅ VFS.moveItem: 移动完成")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        return VirtualFileItem(
            id: newFileId,
            name: itemName,
            isDirectory: isDirectory,
            size: 0,
            modifiedAt: Date(),
            parentId: newParentId,
            syncStatus: .synced,
            remotePath: destinationPath
        )
    }
}

// MARK: - Storage Type

/// 保险库信息
public struct VaultInfo: Identifiable, Codable, Hashable {
    public let id: String
    public let name: String
    public let storagePath: String
    public let createdAt: Date
    
    // WebDAV 配置
    public var webdavURL: String?
    public var webdavUsername: String?
    
    // 挂载状态（不持久化，运行时状态）
    public var isMounted: Bool = false
    
    // 显式 public 初始化器
    public init(
        id: String,
        name: String,
        storagePath: String,
        createdAt: Date,
        webdavURL: String? = nil,
        webdavUsername: String? = nil,
        isMounted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.storagePath = storagePath
        self.createdAt = createdAt
        self.webdavURL = webdavURL
        self.webdavUsername = webdavUsername
        self.isMounted = isMounted
    }
    
    // 自定义 Codable 实现，排除 isMounted
    enum CodingKeys: String, CodingKey {
        case id, name, storagePath, createdAt, webdavURL, webdavUsername
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        storagePath = try container.decode(String.self, forKey: .storagePath)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        webdavURL = try container.decodeIfPresent(String.self, forKey: .webdavURL)
        webdavUsername = try container.decodeIfPresent(String.self, forKey: .webdavUsername)
        isMounted = false  // 默认未挂载
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(storagePath, forKey: .storagePath)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(webdavURL, forKey: .webdavURL)
        try container.encodeIfPresent(webdavUsername, forKey: .webdavUsername)
        // 不编码 isMounted
    }
    
    // Hashable conformance
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    public static func == (lhs: VaultInfo, rhs: VaultInfo) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Models

/// 虚拟文件项
public struct VirtualFileItem {
    public let id: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modifiedAt: Date
    public let parentId: String
    
    // 同步状态相关
    public var syncStatus: SyncStatus
    public var localPath: String?
    public var remotePath: String?
    
    public init(
        id: String,
        name: String,
        isDirectory: Bool,
        size: Int64,
        modifiedAt: Date,
        parentId: String,
        syncStatus: SyncStatus = .synced,
        localPath: String? = nil,
        remotePath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
        self.parentId = parentId
        self.syncStatus = syncStatus
        self.localPath = localPath
        self.remotePath = remotePath
    }
}

/// 保险库配置
struct VaultConfig: Codable {
    let vaultId: String
    let version: Int
    let cipherCombo: String
    let createdAt: Date
    let salt: Data
}

/// 目录元数据
struct DirectoryMetadata: Codable {
    let name: String
}

/// 保险库配置（无加密）
struct VaultConfigNoEncryption: Codable {
    let vaultId: String
    let version: Int
    let encrypted: Bool
    let createdAt: Date
}
