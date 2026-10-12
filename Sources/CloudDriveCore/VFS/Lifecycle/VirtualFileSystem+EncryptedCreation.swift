import Foundation
import CryptomatorCryptoLib

extension VirtualFileSystem {
    public func initializeVault(name: String, password: String, storagePath: String, vaultId requestedVaultId: String? = nil) async throws -> String {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("🔧 [VFS] Initializing vault")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📂 [VFS] Storage path: \(storagePath)")
        print("🏠 [VFS] Storage type: WebDAV")
        
        guard let storageClient = storageClient else {
            print("❌ [VFS] storageClient not configured")
            throw VFSError.storageNotConfigured
        }
        print("✅ [VFS] storageClient configured")
        
        // 1. 生成主密钥
        print("🔑 [VFS] Generating master key...")
        let (masterKey, _) = try encryption.generateMasterKey(password: password)
        print("✅ [VFS] Master key generated successfully")
        
        // 2. 创建加密的保险库结构
        let vaultId = requestedVaultId ?? name
        let cleanStoragePath = storagePath == "/" ? "" : storagePath
        let vaultPath: String
        if cleanStoragePath.hasSuffix("/\(name)") || cleanStoragePath == name || cleanStoragePath == "/\(name)" {
            vaultPath = cleanStoragePath.hasPrefix("/") ? cleanStoragePath : "/\(cleanStoragePath)"
        } else {
            vaultPath = "\(cleanStoragePath)/\(name)"
        }
        print("📁 [VFS] Vault path: \(vaultPath)")
        
        let configPath = "\(vaultPath)/vault.cryptomator"
        let masterkeyPath = "\(vaultPath)/masterkey.cryptomator"
        let saltPath = "\(vaultPath)/salt"
        let dDirPath = "\(vaultPath)/d"

        // 检查是否已存在保险库，严禁覆盖现有保险库及其主密钥
        let configExists = (try? await storageClient.exists(path: configPath)) ?? false
        let masterkeyExists = (try? await storageClient.exists(path: masterkeyPath)) ?? false
        let dDirExists = (try? await storageClient.exists(path: dDirPath)) ?? false
        let saltExists = (try? await storageClient.exists(path: saltPath)) ?? false
        if configExists || masterkeyExists || dDirExists || saltExists {
            print("❌ [VFS] Vault already exists at \(vaultPath), aborting initialization to prevent key destruction")
            throw VFSError.vaultAlreadyExists(vaultPath)
        }
        
        // 创建保险库目录结构
        do {
            print("📁 [VFS] Creating root directory...")
            try await storageClient.createDirectory(path: vaultPath)
            print("✅ [VFS] Root directory created successfully")
            
            print("⏳ [VFS] Waiting 1 second for WebDAV server cache delay...")
            try await Task.sleep(nanoseconds: 1_000_000_000)
            
            print("📁 [VFS] Creating d directory (Cryptomator storage directory)...")
            try await storageClient.createDirectory(path: dDirPath)
            print("✅ [VFS] d directory created successfully")
            
            // 验证目录是否真的创建成功
            let dExists = try await storageClient.exists(path: dDirPath)
            print("🔍 [VFS] Directory verification - d: \(dExists ? "✅" : "❌")")
            
            if !dExists {
                throw VFSError.directoryCreationFailed("d directory verification failed after creation")
            }
            
        } catch let vfsError as VFSError {
            throw vfsError
        } catch {
            print("❌ [VFS] Failed to create directory: \(error)")
            throw VFSError.directoryCreationFailed(error.localizedDescription)
        }
        
        // 3. 创建保险库配置文件
        print("📝 [VFS] Creating vault configuration...")
        
        do {
            let tempDir = FileManager.default.temporaryDirectory
            
            // 1. 创建并保存标准 Cryptomator Format 8 vault.cryptomator (JWT 配置文件)
            let (_, jwtData) = try CryptomatorVaultConfig.create(masterKey: masterKey, cipherCombo: "SIV_GCM", shorteningThreshold: 220)
            let tempConfigURL = tempDir.appendingPathComponent("config_\(UUID().uuidString)")
            try jwtData.write(to: tempConfigURL, options: [.atomic])
            print("💾 [VFS] Writing standard Format 8 vault.cryptomator: \(tempConfigURL.path)")
            defer { try? FileManager.default.removeItem(at: tempConfigURL) }
            try await storageClient.uploadFile(localURL: tempConfigURL, to: configPath, mode: .createIfAbsent) { _ in }
            print("✅ [VFS] Standard vault.cryptomator (JWT) uploaded successfully")
            
            // 2. 创建并保存标准 Cryptomator masterkey.cryptomator 文件
            let masterkeyData = try MasterkeyFile.lock(masterkey: masterKey, vaultVersion: 8, passphrase: password)
            let tempMasterkeyURL = tempDir.appendingPathComponent("masterkey_\(UUID().uuidString)")
            try masterkeyData.write(to: tempMasterkeyURL, options: [.atomic])
            print("💾 [VFS] Writing temporary masterkey file: \(tempMasterkeyURL.path)")
            defer { try? FileManager.default.removeItem(at: tempMasterkeyURL) }
            try await storageClient.uploadFile(localURL: tempMasterkeyURL, to: masterkeyPath, mode: .createIfAbsent) { _ in }
            print("✅ [VFS] Standard masterkey.cryptomator written successfully")
            // Standard Format 8 does not store unencrypted raw masterkey on remote storage.
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
            print("   Error details: \(error.localizedDescription)")
            if let nsError = error as NSError? {
                print("   Domain: \(nsError.domain)")
                print("   Code: \(nsError.code)")
                print("   UserInfo: \(nsError.userInfo)")
            }
            throw error
        }
        
        if let client = self.storageClient {
            cryptomatorFormat = CryptomatorFormat(masterkey: masterKey, storageClient: client, basePath: vaultPath, scheme: .sivGcm, shorteningThreshold: 220)
        }

        // 5. 创建根目录映射
        print("📁 [VFS] Creating root directory mapping...")
        do {
            let rootDirId = ""
            let rootDirData = Data([]) // ROOT is empty data in CryptomatorFormat
            let rootRemotePath = try cryptomatorFormat!.getDirPath(dirId: rootDirData)
            print("🔐 [VFS] Root directory ID encrypted: ROOT, remote path: \(rootRemotePath)")
            
            // 在远程存储上创建加密根目录
            try await storageClient.createDirectory(path: rootRemotePath)
            print("📁 [VFS] Remote encrypted root directory created")
            
            try database.insertDirectory(
                id: rootId,
                name: "Root",
                parentId: nil,
                encryptedId: rootDirId,
                remotePath: rootRemotePath
            )
            print("✅ [VFS] Root directory mapping created")
        } catch {
            print("❌ [VFS] Failed to create root directory mapping: \(error)")
            throw VFSError.databaseError("Failed to create root directory mapping: \(error.localizedDescription)")
        }
        
        // 6. 保存主密钥到内存和密钥链
        encryption.setMasterKey(masterKey)
        self.currentVaultId = vaultId
        self.isEncryptedVault = true
        self.isDirectMappingVault = false
        if let cf = self.cryptomatorFormat, let sc = self.storageClient {
            self.activeProvider = EncryptedVFSProvider(
                vaultId: vaultId,
                cryptomatorFormat: cf,
                storageClient: sc,
                database: database,
                syncManager: syncManager,
                cacheManager: cacheManager
            )
        }
        do {
            try CredentialStore.shared.storeMasterKey(masterKey, forVault: vaultId)
            print("🔑 [VFS] Master key saved to memory and keychain (encrypted mode active)")
        } catch {
            print("⚠️ [VFS] Failed to save master key to keychain (saved in memory, encrypted mode active normally): \(error)")
        }
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("✅ [VFS] Vault initialization completed")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        return vaultId
    }
}
