import Foundation
import CryptomatorCryptoLib

extension VirtualFileSystem {
    public func initializeDirectMappingVault(vaultId: String, storagePath: String) async throws {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("🔗 [VFS] Initializing direct mapping vault")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📂 [VFS] Vault ID: \(vaultId)")
        print("📂 [VFS] Storage path: \(storagePath)")
        
        guard let storageClient = storageClient else {
            print("❌ [VFS] storageClient not configured")
            throw VFSError.storageNotConfigured
        }
        print("✅ [VFS] storageClient configured")
        
        // 1. 初始化本地数据库
        print("💾 [VFS] Initializing local database...")
        self.currentVaultId = vaultId
        self.database = VFSDatabase(vaultId: vaultId)
        do {
            try database.initialize(vaultId: vaultId, basePath: storagePath)
            print("✅ [VFS] Database initialized successfully")
        } catch {
            print("❌ [VFS] Database initialization failed: \(error)")
            throw error
        }
        
        // 2. 创建根目录映射（直接映射到 WebDAV 根目录）
        // 检查根目录是否已存在
        print("📁 [VFS] Checking root directory mapping...")
        if let existingRoot = try? database.getDirectory(id: rootId) {
            print("✅ [VFS] Root directory mapping already exists, skipping creation")
            print("   Existing path: \(existingRoot.remotePath)")
        } else {
            print("📁 [VFS] Creating root directory mapping...")
            do {
                try database.insertDirectory(
                    id: rootId,
                    name: "Root",
                    parentId: nil,
                    encryptedId: rootId,
                    remotePath: storagePath  // 直接映射到根路径
                )
                print("✅ [VFS] Root directory mapping created")
            } catch {
                print("❌ [VFS] Failed to create root directory mapping: \(error)")
                throw VFSError.databaseError("Failed to create root directory mapping: \(error.localizedDescription)")
            }
        }
        
        // 3. 保存保险库 ID
        self.currentVaultId = vaultId
        self.isEncryptedVault = false
        self.isDirectMappingVault = true
        self.activeProvider = DirectMappingVFSProvider(
            vaultId: vaultId,
            storagePath: storagePath,
            storageClient: storageClient,
            database: database,
                syncManager: syncManager,
                cacheManager: cacheManager
        )
        print("🔑 [VFS] Vault ID saved (direct mapping mode)")
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("✅ [VFS] Direct mapping vault initialization completed")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    }

    public func isVaultMounted(vaultId: String) -> Bool {
        return currentVaultId == vaultId
    }

    public func remountDirectMappingVault(vaultId: String, storagePath: String) async throws {
        print("🔓 [VFS] Remounting direct mapping vault")
        print("   Vault ID: \(vaultId)")
        print("   Storage path: \(storagePath)")
        
        // 检查 WebDAV 配置
        guard let storageClient = storageClient else {
            throw VFSError.storageNotConfigured
        }
        print("✅ [VFS] storageClient configured")
        
        // 检查是否已经是同一个保险库且已挂载
        if let currentVaultId = currentVaultId, currentVaultId == vaultId, activeProvider != nil {
            print("✅ [VFS] Same vault already mounted, skipping")
            return
        }
        
        self.isEncryptedVault = false
        self.isDirectMappingVault = true
        
        // 如果挂载了其他保险库，先锁定
        if currentVaultId != nil {
            print("⚠️ [VFS] Other vault mounted detected, locking first")
            lock()
        }
        
        // 加载数据库
        print("💾 [VFS] Loading database...")
        self.currentVaultId = vaultId
        self.database = VFSDatabase(vaultId: vaultId)
        do {
            try database.load(vaultId: vaultId, basePath: storagePath)
            print("✅ [VFS] Database loaded successfully")
        } catch {
            print("❌ [VFS] Database load failed: \(error)")
            
            // 如果数据库加载失败，尝试重新初始化（可能数据库文件被删除）
            print("🔄 [VFS] Attempting to reinitialize database...")
            try await initializeDirectMappingVault(vaultId: vaultId, storagePath: storagePath)
            print("✅ [VFS] Database reinitialized successfully")
        }
        
        // 保存保险库 ID
        self.currentVaultId = vaultId
        self.activeProvider = DirectMappingVFSProvider(
            vaultId: vaultId,
            storagePath: storagePath,
            storageClient: storageClient,
            database: database,
                syncManager: syncManager,
                cacheManager: cacheManager
        )
        print("✅ [VFS] Direct mapping vault remounted successfully")
    }

    public func mountVaultWithoutEncryption(storagePath: String, vaultId: String) async throws {
        print("🔓 [VFS] Mounting vault (unencrypted mode)")
        print("   Vault ID: \(vaultId)")
        print("   Storage path: \(storagePath)")
        
        guard let storageClient = storageClient else {
            throw VFSError.storageNotConfigured
        }
        
        // 检查是否已经是同一个保险库
        if let currentVaultId = currentVaultId, currentVaultId == vaultId {
            print("✅ [VFS] Same vault already mounted, skipping")
            return
        }
        
        // 如果挂载了其他保险库，先锁定
        if currentVaultId != nil {
            print("⚠️ [VFS] Other vault mounted detected, locking first")
            lock()
        }
        
        // 1. 读取配置文件
        let configPath = "\(storagePath)/\(vaultId)/vault.config"
        
        do {
            print("📥 [VFS] Reading configuration file...")
            let tempDir = FileManager.default.temporaryDirectory
            let tempConfigURL = tempDir.appendingPathComponent("config_\(UUID().uuidString)")
            
            try await storageClient.downloadFile(path: configPath, to: tempConfigURL) { _ in }
            let configData = try Data(contentsOf: tempConfigURL)
            
            // 清理临时文件
            try? FileManager.default.removeItem(at: tempConfigURL)
            
            let vaultConfig = try JSONDecoder().decode(VaultConfigNoEncryption.self, from: configData)
            print("✅ [VFS] Configuration file read successfully")
            
            // 2. 加载本地数据库
            print("💾 [VFS] Loading database...")
            self.currentVaultId = vaultConfig.vaultId
            self.database = VFSDatabase(vaultId: vaultConfig.vaultId)
            try database.load(vaultId: vaultConfig.vaultId, basePath: "\(storagePath)/\(vaultId)")
            print("✅ [VFS] Database loaded successfully")
            
            // 3. 保存保险库 ID
            self.currentVaultId = vaultConfig.vaultId
            self.activeProvider = DirectMappingVFSProvider(
                vaultId: vaultConfig.vaultId,
                storagePath: "\(storagePath)/\(vaultId)",
                storageClient: storageClient,
                database: database,
                syncManager: syncManager,
                cacheManager: cacheManager
            )
            print("✅ [VFS] Vault mounted successfully (unencrypted mode)")
            
        } catch {
            print("❌ [VFS] Mount failed: \(error)")
            throw error
        }
    }
}
