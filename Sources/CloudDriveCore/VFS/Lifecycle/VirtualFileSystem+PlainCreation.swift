import Foundation
import CryptomatorCryptoLib

extension VirtualFileSystem {
    public func initializeVaultWithoutEncryption(name: String, storagePath: String) async throws -> String {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("🔧 [VFS] Initializing vault (unencrypted mode)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📂 [VFS] Storage path: \(storagePath)")
        print("🏠 [VFS] Storage type: WebDAV")
        
        guard let storageClient = storageClient else {
            print("❌ [VFS] storageClient not configured")
            throw VFSError.storageNotConfigured
        }
        print("✅ [VFS] storageClient configured")
        
        // 1. 生成保险库 ID
        let vaultId = name // 使用用户指定的名称作为 vaultId
        let cleanStoragePath = storagePath == "/" ? "" : storagePath
        let vaultPath = "\(cleanStoragePath)/\(vaultId)"
        print("📁 [VFS] Vault path: \(vaultPath)")

        let configPath = "\(vaultPath)/vault.config"
        let filesDirPath = "\(vaultPath)/files"
        let configExists = (try? await storageClient.exists(path: configPath)) ?? false
        let filesExists = (try? await storageClient.exists(path: filesDirPath)) ?? false
        if configExists || filesExists {
            print("❌ [VFS] Vault already exists at \(vaultPath), aborting initialization")
            throw VFSError.vaultAlreadyExists(vaultPath)
        }
        
        // 2. 创建保险库目录结构
        do {
            print("📁 [VFS] Creating root directory...")
            try await storageClient.createDirectory(path: vaultPath)
            print("✅ [VFS] Root directory created successfully")
            
            print("📁 [VFS] Creating files directory (storing files)...")
            try await storageClient.createDirectory(path: filesDirPath)
            print("✅ [VFS] files directory created successfully")
            
            // 验证目录是否真的创建成功
            let filesExists = try await storageClient.exists(path: filesDirPath)
            print("🔍 [VFS] Directory verification - files: \(filesExists ? "✅" : "❌")")
            
            if !filesExists {
                throw VFSError.directoryCreationFailed("Directory verification failed after creation")
            }
            
        } catch let vfsError as VFSError {
            throw vfsError
        } catch {
            print("❌ [VFS] Failed to create directory: \(error)")
            throw VFSError.directoryCreationFailed(error.localizedDescription)
        }
        
        // 3. 创建保险库配置文件（无加密）
        print("📝 [VFS] Creating vault configuration...")
        
        do {
            let vaultConfig = VaultConfigNoEncryption(
                vaultId: vaultId,
                version: 1,
                encrypted: false,
                createdAt: Date()
            )
            
            let configData = try JSONEncoder().encode(vaultConfig)
            print("📊 [VFS] Configuration data size: \(configData.count) bytes")
            
            // 使用临时文件上传
            let tempDir = FileManager.default.temporaryDirectory
            let tempConfigURL = tempDir.appendingPathComponent("config_\(UUID().uuidString)")
            
            try configData.write(to: tempConfigURL, options: [.atomic])
            print("💾 [VFS] Writing temporary configuration file: \(tempConfigURL.path)")
            defer { try? FileManager.default.removeItem(at: tempConfigURL) }
            
            // 通过 storageClient 上传配置文件 (createIfAbsent)
            try await storageClient.uploadFile(localURL: tempConfigURL, to: configPath, mode: .createIfAbsent) { _ in }
            print("✅ [VFS] Configuration file written successfully")
            
        } catch let vfsError as VFSError {
            throw vfsError
        } catch StorageError.serverError(let code, _) where code == 412 {
            throw VFSError.vaultAlreadyExists(vaultPath)
        } catch {
            print("❌ [VFS] Configuration file creation failed: \(error)")
            throw VFSError.fileOperationFailed("Configuration file creation failed: \(error.localizedDescription)")
        }
        
        // 4. 初始化本地数据库
        print("💾 [VFS] Initializing local database...")
        self.currentVaultId = vaultId
        self.database = VFSDatabase(vaultId: vaultId)
        do {
            try database.initialize(vaultId: vaultId, basePath: vaultPath)
            print("✅ [VFS] Database initialized successfully")
        } catch {
            print("❌ [VFS] Database initialization failed: \(error)")
            throw error
        }
        
        // 5. 创建根目录映射（无加密）
        print("📁 [VFS] Creating root directory mapping...")
        do {
            try database.insertDirectory(
                id: rootId,
                name: "Root",
                parentId: nil,
                encryptedId: rootId,
                remotePath: "\(vaultPath)/files"
            )
            print("✅ [VFS] Root directory mapping created")
        } catch {
            print("❌ [VFS] Failed to create root directory mapping: \(error)")
            throw VFSError.databaseError("Failed to create root directory mapping: \(error.localizedDescription)")
        }
        
        // 6. 保存保险库 ID 并激活驱动
        self.currentVaultId = vaultId
        self.isEncryptedVault = false
        self.isDirectMappingVault = true
        self.activeProvider = DirectMappingVFSProvider(
            vaultId: vaultId,
            storagePath: "\(cleanStoragePath)/\(vaultId)",
            storageClient: storageClient,
            database: database,
                syncManager: syncManager,
                cacheManager: cacheManager
        )
        print("🔑 [VFS] Vault ID saved & DirectMapping provider activated")
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("✅ [VFS] Vault initialization completed (unencrypted mode)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        return vaultId
    }
}
