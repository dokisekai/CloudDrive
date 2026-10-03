import Foundation
import CryptomatorCryptoLib

extension VirtualFileSystem {
    public func changeVaultPassword(oldPassword: String, newPassword: String, storagePath: String, vaultId: String) async throws {
        print("🔐 [VFS] Starting changeVaultPassword for vault: \(vaultId)")
        guard let storageClient = storageClient else {
            throw VFSError.storageNotConfigured
        }
        
        let vaultPath = await resolveVaultPath(storagePath: storagePath, vaultId: vaultId)
        let cleanVaultPath = vaultPath == "/" ? "" : (vaultPath.hasSuffix("/") ? String(vaultPath.dropLast()) : vaultPath)
        
        let masterkeyPath = "\(cleanVaultPath)/masterkey.cryptomator"
        let bkupPath = "\(cleanVaultPath)/masterkey.cryptomator.bkup"
        let saltPath = "\(cleanVaultPath)/salt"
        let configPath = "\(cleanVaultPath)/vault.cryptomator"
        
        let tempDir = FileManager.default.temporaryDirectory
        
        var masterKey: Masterkey? = nil
        var originalMKData: Data? = nil
        
        let hasMasterkey = (try? await storageClient.exists(path: masterkeyPath)) ?? false
        
        if hasMasterkey {
            let tempMKURL = tempDir.appendingPathComponent("mk_chg_\(UUID().uuidString)")
            do {
                try await storageClient.downloadFile(path: masterkeyPath, to: tempMKURL) { _ in }
                let mkData = try Data(contentsOf: tempMKURL)
                try? FileManager.default.removeItem(at: tempMKURL)
                originalMKData = mkData
                
                let masterkeyFile = try MasterkeyFile.withContentFromData(data: mkData)
                masterKey = try masterkeyFile.unlock(passphrase: oldPassword)
            } catch {
                try? FileManager.default.removeItem(at: tempMKURL)
                print("❌ [VFS] Failed to unlock masterkey with old password: \(error)")
                throw VFSError.invalidPassword
            }
            
            // 如果存在 vault.cryptomator JWT，进一步验证签名
            let hasConfig = (try? await storageClient.exists(path: configPath)) ?? false
            if hasConfig, let unlockedKey = masterKey {
                let tempConfigURL = tempDir.appendingPathComponent("cfg_chg_\(UUID().uuidString)")
                if (try? await storageClient.downloadFile(path: configPath, to: tempConfigURL) { _ in }) != nil,
                   let cfgData = try? Data(contentsOf: tempConfigURL),
                   let cfgStr = String(data: cfgData, encoding: .utf8),
                   let jwtConfig = try? CryptomatorVaultConfig.decodeUnverified(jwtString: cfgStr) {
                    try? FileManager.default.removeItem(at: tempConfigURL)
                    if !jwtConfig.verifySignature(masterKey: unlockedKey) {
                        print("❌ [VFS] JWT signature verification failed with unlocked key")
                        throw VFSError.invalidPassword
                    }
                } else {
                    try? FileManager.default.removeItem(at: tempConfigURL)
                }
            }
        } else {
            // 旧版兼容模式: salt + 旧版 AES 加密的 vault.cryptomator
            let hasSalt = (try? await storageClient.exists(path: saltPath)) ?? false
            let hasConfig = (try? await storageClient.exists(path: configPath)) ?? false
            guard hasSalt && hasConfig else {
                throw VFSError.vaultNotFound(cleanVaultPath.isEmpty ? "/" : cleanVaultPath)
            }
            
            let tempSaltURL = tempDir.appendingPathComponent("salt_chg_\(UUID().uuidString)")
            try await storageClient.downloadFile(path: saltPath, to: tempSaltURL) { _ in }
            let salt = try Data(contentsOf: tempSaltURL)
            try? FileManager.default.removeItem(at: tempSaltURL)
            
            let tempConfigURL = tempDir.appendingPathComponent("cfg_chg_\(UUID().uuidString)")
            try await storageClient.downloadFile(path: configPath, to: tempConfigURL) { _ in }
            let encryptedConfig = try Data(contentsOf: tempConfigURL)
            try? FileManager.default.removeItem(at: tempConfigURL)
            
            do {
                let derivedKey = try encryption.deriveMasterKey(password: oldPassword, salt: salt)
                let configData = try encryption.decrypt(data: encryptedConfig, key: derivedKey)
                _ = try JSONDecoder().decode(VaultConfig.self, from: configData)
                masterKey = derivedKey
            } catch {
                throw VFSError.invalidPassword
            }
        }
        
        guard let finalMasterKey = masterKey else {
            throw VFSError.invalidPassword
        }
        
        // 1. 使用新密码重新锁定 masterKey 生成标准 Format 8 密钥文件
        let newMKData = try MasterkeyFile.lock(masterkey: finalMasterKey, vaultVersion: 8, passphrase: newPassword)
        
        // 2. 如果存在旧的 masterkey 数据，备份为 masterkey.cryptomator.bkup
        if let origData = originalMKData {
            let tempBkupURL = tempDir.appendingPathComponent("mk_bkup_\(UUID().uuidString)")
            try origData.write(to: tempBkupURL, options: [.atomic])
            defer { try? FileManager.default.removeItem(at: tempBkupURL) }
            try? await storageClient.uploadFile(localURL: tempBkupURL, to: bkupPath, mode: .forceOverwrite) { _ in }
            print("✅ [VFS] Backup saved to \(bkupPath)")
        }
        
        // 3. 上传新加密的 masterkey.cryptomator (覆盖写入)
        let tempNewMKURL = tempDir.appendingPathComponent("mk_new_\(UUID().uuidString)")
        try newMKData.write(to: tempNewMKURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: tempNewMKURL) }
        try await storageClient.uploadFile(localURL: tempNewMKURL, to: masterkeyPath, mode: .forceOverwrite) { _ in }
        print("✅ [VFS] New masterkey.cryptomator uploaded successfully")
        
        // 4. 确保存在标准的 Format 8 vault.cryptomator JWT
        let hasConfig = (try? await storageClient.exists(path: configPath)) ?? false
        if !hasConfig {
            let (_, jwtData) = try CryptomatorVaultConfig.create(masterKey: finalMasterKey, cipherCombo: "SIV_GCM")
            let tempJWTURL = tempDir.appendingPathComponent("jwt_new_\(UUID().uuidString)")
            try jwtData.write(to: tempJWTURL, options: [.atomic])
            defer { try? FileManager.default.removeItem(at: tempJWTURL) }
            try? await storageClient.uploadFile(localURL: tempJWTURL, to: configPath, mode: .createIfAbsent) { _ in }
            print("✅ [VFS] Standard Format 8 vault.cryptomator created successfully")
        }
        
        // 5. 如果当前已挂载且 ID 匹配，同步更新内存与 Keychain
        if self.currentVaultId == vaultId {
            self.encryption.setMasterKey(finalMasterKey)
            try? CredentialStore.shared.storeMasterKey(finalMasterKey, forVault: vaultId)
        }
        
        print("🎉 [VFS] Vault password changed successfully for vault: \(vaultId)")
    }
}
