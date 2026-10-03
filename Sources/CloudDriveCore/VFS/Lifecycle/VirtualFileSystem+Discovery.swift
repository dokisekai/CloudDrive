import Foundation
import CryptomatorCryptoLib

extension VirtualFileSystem {
    public func resolveVaultPath(storagePath: String, vaultId: String) async -> String {
        guard let storageClient = storageClient else { return storagePath }
        
        var cleanStorage = storagePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanStorage.hasPrefix("/") {
            cleanStorage = "/" + cleanStorage
        }
        while cleanStorage.hasSuffix("/") && cleanStorage.count > 1 {
            cleanStorage = String(cleanStorage.dropLast())
        }
        
        // 候选 1: storagePath 自身（例如用户直接指定了 /MyVault，或者根目录 /）
        let basePath1 = cleanStorage == "/" ? "" : cleanStorage
        let hasMK1 = (try? await storageClient.exists(path: "\(basePath1)/masterkey.cryptomator")) ?? false
        let hasSalt1 = (try? await storageClient.exists(path: "\(basePath1)/salt")) ?? false
        let hasConfig1 = (try? await storageClient.exists(path: "\(basePath1)/vault.cryptomator")) ?? false
        let hasD1 = (try? await storageClient.exists(path: "\(basePath1)/d")) ?? false
        
        if hasMK1 || (hasSalt1 && hasConfig1) || hasD1 {
            return cleanStorage
        }
        
        // 候选 2: storagePath/vaultId（如果用户旧版创建时 storagePath 填了 "/"，真正的保险库在 /vaultId）
        let cleanVaultId = vaultId.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !cleanVaultId.isEmpty {
            let pathWithVaultId = basePath1.isEmpty ? "/\(cleanVaultId)" : "\(basePath1)/\(cleanVaultId)"
            let hasMK2 = (try? await storageClient.exists(path: "\(pathWithVaultId)/masterkey.cryptomator")) ?? false
            let hasSalt2 = (try? await storageClient.exists(path: "\(pathWithVaultId)/salt")) ?? false
            let hasConfig2 = (try? await storageClient.exists(path: "\(pathWithVaultId)/vault.cryptomator")) ?? false
            let hasD2 = (try? await storageClient.exists(path: "\(pathWithVaultId)/d")) ?? false
            
            if hasMK2 || (hasSalt2 && hasConfig2) || hasD2 {
                return pathWithVaultId
            }
        }
        
        return cleanStorage
    }

    public func checkExistingVault(storagePath: String) async -> (exists: Bool, isStandardCryptomator: Bool, resolvedPath: String) {
        guard let storageClient = storageClient else {
            return (false, false, storagePath)
        }
        let resolved = await resolveVaultPath(storagePath: storagePath, vaultId: "")
        let basePath = resolved == "/" ? "" : (resolved.hasSuffix("/") ? String(resolved.dropLast()) : resolved)
        
        let hasMK = (try? await storageClient.exists(path: "\(basePath)/masterkey.cryptomator")) ?? false
        let hasConfig = (try? await storageClient.exists(path: "\(basePath)/vault.cryptomator")) ?? false
        let hasD = (try? await storageClient.exists(path: "\(basePath)/d")) ?? false
        let hasSalt = (try? await storageClient.exists(path: "\(basePath)/salt")) ?? false
        
        if hasMK || (hasConfig && hasD) {
            return (true, true, resolved)
        }
        if hasSalt && hasConfig {
            return (true, false, resolved)
        }
        if hasD {
            return (true, true, resolved)
        }
        return (false, false, resolved)
    }
}
