import Foundation
import CryptomatorCryptoLib

extension VirtualFileSystem {
    public func unlockVault(password: String, storagePath: String, vaultId: String) async throws {
        print("🔓 [VFS] Unlocking vault")
        print("   Vault ID: \(vaultId)")
        print("   Storage path: \(storagePath)")
        
        guard let storageClient = storageClient else {
            throw VFSError.storageNotConfigured
        }
        
        let vaultPath = await resolveVaultPath(storagePath: storagePath, vaultId: vaultId)
        let cleanVaultPath = vaultPath == "/" ? "" : (vaultPath.hasSuffix("/") ? String(vaultPath.dropLast()) : vaultPath)
        print("📁 [VFS] Resolved vault path: '\(cleanVaultPath.isEmpty ? "/" : cleanVaultPath)'")
        
        let configPath = "\(cleanVaultPath)/vault.cryptomator"
        let masterkeyPath = "\(cleanVaultPath)/masterkey.cryptomator"
        let saltPath = "\(cleanVaultPath)/salt"
        
        var masterKey: Masterkey? = nil
        var detectedScheme: CryptorScheme = .sivGcm
        var shorteningThreshold: Int = 220
        let tempDir = FileManager.default.temporaryDirectory
        
        let hasConfig = (try? await storageClient.exists(path: configPath)) ?? false
        let hasMasterkey = (try? await storageClient.exists(path: masterkeyPath)) ?? false
        logInfo(.system, "🔍 [VFS] Checking vault files existence - configPath: \(configPath) (exists: \(hasConfig)), masterkeyPath: \(masterkeyPath) (exists: \(hasMasterkey))")
        
        // 模式 1: 标准 Cryptomator Format 8 (具有 vault.cryptomator JWT 配置)
        if hasConfig {
            let tempConfigURL = tempDir.appendingPathComponent("config_\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tempConfigURL) }
            
            do {
                try await storageClient.downloadFile(path: configPath, to: tempConfigURL) { _ in }
            } catch {
                logError(.system, "❌ [VFS] Failed to download vault.cryptomator (path: \(configPath)): \(error)")
                throw VFSError.fileOperationFailed("Failed to read vault.cryptomator: \(error)")
            }
            
            guard let configData = try? Data(contentsOf: tempConfigURL),
                  let configStr = String(data: configData, encoding: .utf8) else {
                throw VFSError.fileOperationFailed("Corrupted vault.cryptomator content")
            }
            
            // 解析 Format 8 JWT（严格白名单校验算法、kid 穿越、格式等，必须 fail closed）
            let jwtConfig: CryptomatorVaultConfig
            do {
                jwtConfig = try CryptomatorVaultConfig.decodeUnverified(jwtString: configStr)
            } catch {
                logError(.system, "❌ [VFS] Invalid vault.cryptomator JWT configuration: \(error)")
                throw VFSError.fileOperationFailed("Invalid or tampered vault.cryptomator configuration")
            }
            
            print("📥 [VFS] Detected standard Format 8 vault.cryptomator JWT, kid: \(jwtConfig.header.kid), cipherCombo: \(jwtConfig.payload.cipherCombo)")
            logInfo(.system, "📥 [VFS] Detected standard Format 8 vault.cryptomator JWT, kid: \(jwtConfig.header.kid), cipherCombo: \(jwtConfig.payload.cipherCombo)")
            
            var mkPath = masterkeyPath
            if jwtConfig.header.kid.hasPrefix("masterkeyfile:") {
                let mkFile = String(jwtConfig.header.kid.dropFirst(14))
                mkPath = "\(cleanVaultPath)/\(mkFile)"
            }
            
            let tempMKURL = tempDir.appendingPathComponent("mk_\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tempMKURL) }
            let mkData: Data
            do {
                logInfo(.system, "📥 [VFS] Preparing to download masterkey: \(mkPath)")
                try await storageClient.downloadFile(path: mkPath, to: tempMKURL) { _ in }
                mkData = try Data(contentsOf: tempMKURL)
            } catch {
                logError(.system, "❌ [VFS] Failed to download Format 8 masterkey (path: \(mkPath)): \(error)")
                throw error
            }
            
            let masterkeyFile: MasterkeyFile
            let unlockedKey: Masterkey
            do {
                logInfo(.system, "📥 [VFS] Successfully read masterkey data (\(mkData.count) bytes), unlocking...")
                masterkeyFile = try MasterkeyFile.withContentFromData(data: mkData)
                unlockedKey = try masterkeyFile.unlock(passphrase: password)
            } catch {
                print("❌ [VFS] masterkey unlock failed, password may be incorrect: \(error)")
                logError(.system, "❌ [VFS] Format 8 masterkey decryption failed (password may be incorrect): \(error)")
                throw VFSError.invalidPassword
            }
            
            // 验证 JWT HMAC 签名完整性
            guard jwtConfig.verifySignature(masterKey: unlockedKey) else {
                logError(.system, "❌ [VFS] vault.cryptomator JWT signature verification failed")
                throw VFSError.fileOperationFailed("Vault configuration signature verification failed")
            }
            
            print("✅ [VFS] vault.cryptomator JWT signature verification succeeded!")
            logSuccess(.system, "✅ [VFS] vault.cryptomator JWT signature verification succeeded!")
            
            masterKey = unlockedKey
            detectedScheme = (jwtConfig.payload.cipherCombo == "SIV_CTRMAC") ? .sivCtrMac : .sivGcm
            shorteningThreshold = jwtConfig.payload.shorteningThreshold
            print("✅ [VFS] Standard Cryptomator Format 8 unlocked successfully, cipher: \(detectedScheme.rawValue), threshold: \(shorteningThreshold)")
            logSuccess(.system, "✅ [VFS] Standard Cryptomator Format 8 unlocked successfully, cipher: \(detectedScheme.rawValue), threshold: \(shorteningThreshold)")
        }
        
        // 模式 2: 标准 Cryptomator Format 7 (无 vault.cryptomator，仅 masterkey.cryptomator)
        if masterKey == nil && hasMasterkey {
            print("📥 [VFS] Detected standard masterkey.cryptomator (Format 7/8), unlocking...")
            logInfo(.system, "📥 [VFS] Detected standard masterkey.cryptomator (Format 7/8), unlocking...")
            let tempMKURL = tempDir.appendingPathComponent("mk_\(UUID().uuidString)")
            let mkData: Data
            do {
                logInfo(.system, "📥 [VFS] Preparing to download Format 7 masterkey: \(masterkeyPath)")
                try await storageClient.downloadFile(path: masterkeyPath, to: tempMKURL) { _ in }
                mkData = try Data(contentsOf: tempMKURL)
                try? FileManager.default.removeItem(at: tempMKURL)
            } catch {
                try? FileManager.default.removeItem(at: tempMKURL)
                logError(.system, "❌ [VFS] Failed to download Format 7 masterkey (path: \(masterkeyPath)): \(error)")
                throw error
            }
            
            do {
                logInfo(.system, "📥 [VFS] Successfully read masterkey data (\(mkData.count) bytes), unlocking...")
                let masterkeyFile = try MasterkeyFile.withContentFromData(data: mkData)
                masterKey = try masterkeyFile.unlock(passphrase: password)
                if masterkeyFile.version <= 7 {
                    detectedScheme = .sivCtrMac
                } else {
                    detectedScheme = .sivGcm
                }
                print("✅ [VFS] Standard masterkey unlocked successfully (version \(masterkeyFile.version), cipher: \(detectedScheme.rawValue))")
                logSuccess(.system, "✅ [VFS] Standard masterkey unlocked successfully (version \(masterkeyFile.version), cipher: \(detectedScheme.rawValue))")
            } catch {
                print("❌ [VFS] masterkey unlock failed: \(error)")
                logError(.system, "❌ [VFS] Format 7 masterkey decryption failed (password may be incorrect): \(error)")
                throw VFSError.invalidPassword
            }
        }
        
        // 模式 3: 兼容早期自定义版本（salt + 旧版 AES 加密的 vault.cryptomator）
        if masterKey == nil {
            let hasSalt = (try? await storageClient.exists(path: saltPath)) ?? false
            guard hasSalt && hasConfig else {
                throw VFSError.vaultNotFound(cleanVaultPath.isEmpty ? "/" : cleanVaultPath)
            }
            
            print("📥 [VFS] Falling back to read salt and custom vault.cryptomator...")
            let tempSaltURL = tempDir.appendingPathComponent("salt_\(UUID().uuidString)")
            try await storageClient.downloadFile(path: saltPath, to: tempSaltURL) { _ in }
            let salt = try Data(contentsOf: tempSaltURL)
            try? FileManager.default.removeItem(at: tempSaltURL)
            
            let tempConfigURL = tempDir.appendingPathComponent("config_\(UUID().uuidString)")
            try await storageClient.downloadFile(path: configPath, to: tempConfigURL) { _ in }
            let encryptedConfig = try Data(contentsOf: tempConfigURL)
            try? FileManager.default.removeItem(at: tempConfigURL)
            
            do {
                let derivedKey = try encryption.deriveMasterKey(password: password, salt: salt)
                let configData = try encryption.decrypt(data: encryptedConfig, key: derivedKey)
                _ = try JSONDecoder().decode(VaultConfig.self, from: configData)
                masterKey = derivedKey
                detectedScheme = .sivGcm
                print("✅ [VFS] Legacy custom configuration decrypted and verified successfully")
                
                // 自动平滑升级为官方标准 Format 8 (masterkey.cryptomator + vault.cryptomator JWT)
                Task.detached { [storageClient] in
                    if let masterKey = masterKey {
                        if let mkData = try? MasterkeyFile.lock(masterkey: masterKey, vaultVersion: 8, passphrase: password) {
                            let tempMK = tempDir.appendingPathComponent("upgrade_mk_\(UUID().uuidString)")
                            if (try? mkData.write(to: tempMK)) != nil {
                                try? await storageClient.uploadFile(localURL: tempMK, to: masterkeyPath) { _ in }
                                try? FileManager.default.removeItem(at: tempMK)
                            }
                        }
                        if let (_, jwtData) = try? CryptomatorVaultConfig.create(masterKey: masterKey, cipherCombo: "SIV_GCM") {
                            let tempJWT = tempDir.appendingPathComponent("upgrade_jwt_\(UUID().uuidString)")
                            if (try? jwtData.write(to: tempJWT)) != nil {
                                try? await storageClient.uploadFile(localURL: tempJWT, to: configPath) { _ in }
                                try? FileManager.default.removeItem(at: tempJWT)
                            }
                        }
                        print("🎉 [VFS] Automatically upgraded and saved standard Cryptomator Format 8 configuration")
                    }
                }
            } catch {
                print("❌ [VFS] Configuration decryption failed, password may be incorrect: \(error)")
                throw VFSError.invalidPassword
            }
        }
        
        guard let finalMasterKey = masterKey else {
            throw VFSError.invalidPassword
        }
        
        // 4. 加载或初始化本地数据库（容错设计：作为本地元数据缓存，不可因本地数据库异常阻断核心保险库挂载）
        print("💾 [VFS] Loading local database...")
        self.currentVaultId = vaultId
        self.database = VFSDatabase(vaultId: vaultId)
        do {
            try database.load(vaultId: vaultId, basePath: cleanVaultPath)
            print("✅ [VFS] Database loaded successfully")
        } catch {
            print("ℹ️ [VFS] Database verification failed, initializing local database...")
            do {
                try database.initialize(vaultId: vaultId, basePath: cleanVaultPath)
                print("✅ [VFS] Database initialized successfully")
            } catch {
                print("⚠️ [VFS] Local cache database initialization failed, ignoring and continuing in cloud direct read mode: \(error)")
            }
        }
        
        // 5. 配置 CryptomatorFormat，传入匹配的 scheme 和 shorteningThreshold
        cryptomatorFormat = CryptomatorFormat(
            masterkey: finalMasterKey,
            storageClient: storageClient,
            basePath: cleanVaultPath,
            scheme: detectedScheme,
            shorteningThreshold: shorteningThreshold
        )
        
        // 6. 确保根目录映射存在
        let rootDirData = Data([])
        let rootRemotePath = try cryptomatorFormat!.getDirPath(dirId: rootDirData)
        if (try? await storageClient.exists(path: rootRemotePath)) != true {
            try? await storageClient.createDirectory(path: rootRemotePath)
        }
        try? database.insertDirectory(
            id: rootId,
            name: "Root",
            parentId: nil,
            encryptedId: "",
            remotePath: rootRemotePath
        )
        print("✅ [VFS] Root directory mapping ready: \(rootRemotePath)")
        
        // 7. 保存主密钥到内存和密钥链
        encryption.setMasterKey(finalMasterKey)
        self.currentVaultId = vaultId
        self.isEncryptedVault = true
        self.isDirectMappingVault = false
        self.activeProvider = EncryptedVFSProvider(
            vaultId: vaultId,
            cryptomatorFormat: cryptomatorFormat!,
            storageClient: storageClient,
            database: database,
                syncManager: syncManager,
                cacheManager: cacheManager
        )
        do {
            try CredentialStore.shared.storeMasterKey(finalMasterKey, forVault: vaultId)
            print("✅ [VFS] Master key saved to keychain")
        } catch {
            print("⚠️ [VFS] Failed to save master key to keychain (saved in memory, vault unlocked successfully): \(error)")
        }
        print("✅ [VFS] Vault unlocked successfully (encrypted mode active, cipher scheme: \(detectedScheme.rawValue))")
    }
}
