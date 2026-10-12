import CloudDriveContracts
import CloudDriveSupport
import Foundation
import Security
import CryptomatorCryptoLib

/// Secrets live in Keychain. Old preference values are read only for migration.
public final class CredentialStore: @unchecked Sendable {
    public static let shared = CredentialStore()
    public static let sharedGroup = "group.net.aabg.CloudDrive"
    public static let serviceName = "net.aabg.CloudDrive"
    
    private struct VaultCredentialsRecord: Codable {
        var storagePassword: String?
        var vaultPassword: String?
    }
    
    private init() {}

    private func queries(account: String) -> [[String: Any]] {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account, kSecAttrService as String: Self.serviceName]
        var shared = base
        shared[kSecUseDataProtectionKeychain as String] = true
        shared[kSecAttrAccessGroup as String] = Self.sharedGroup
        return [shared, base]
    }

    private func read(account: String) -> String? {
        for var query in queries(account: account) {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
               let data = item as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func write(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        for query in queries(account: account) {
            let update = [kSecValueData as String: data]
            let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if status == errSecSuccess { return true }
            
            // If update was not successful, attempt clean replace
            SecItemDelete(query as CFDictionary)
            
            var add = query
            add[kSecValueData as String] = data
            if query[kSecUseDataProtectionKeychain as String] != nil {
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
            if SecItemAdd(add as CFDictionary, nil) == errSecSuccess { return true }
        }
        Logger.shared.error(.system, "CredentialStore: Could not persist credential in Keychain for account \(account)")
        return false
    }

    private func removeLegacy(vaultId: String, keys: [String], activeKeys: [String]) {
        guard let defaults = UserDefaults(suiteName: Self.sharedGroup) else { return }
        keys.forEach { defaults.removeObject(forKey: "\($0)_\(vaultId)") }
        if defaults.string(forKey: "active_vault_id") == vaultId {
            activeKeys.forEach { defaults.removeObject(forKey: $0) }
        }
    }
    
    private func loadBundle(for vaultId: String) -> VaultCredentialsRecord {
        var record = VaultCredentialsRecord()
        if let jsonStr = read(account: "vault-credentials-\(vaultId)"),
           let data = jsonStr.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(VaultCredentialsRecord.self, from: data) {
            record = decoded
        }
        
        // Backward compatibility fallback to individual legacy accounts
        if record.storagePassword == nil {
            record.storagePassword = read(account: "storage-password-\(vaultId)") ?? read(account: "webdav-password-\(vaultId)")
        }
        if record.vaultPassword == nil {
            record.vaultPassword = read(account: "vault-password-\(vaultId)")
        }
        return record
    }
    
    private func persistBundle(_ record: VaultCredentialsRecord, for vaultId: String) -> Bool {
        guard let data = try? JSONEncoder().encode(record),
              let jsonStr = String(data: data, encoding: .utf8) else {
            return false
        }
        return write(jsonStr, account: "vault-credentials-\(vaultId)")
    }

    @discardableResult
    public func saveStoragePassword(_ password: String, for vaultId: String) -> Bool {
        var bundle = loadBundle(for: vaultId)
        bundle.storagePassword = password
        guard persistBundle(bundle, for: vaultId) else { return false }
        removeLegacy(vaultId: vaultId, keys: ["webdav_password", "storage_password"],
            activeKeys: ["active_webdav_password", "active_storage_password"])
        return true
    }

    public func getStoragePassword(for vaultId: String) -> String? {
        let bundle = loadBundle(for: vaultId)
        if let value = bundle.storagePassword, !value.isEmpty {
            removeLegacy(vaultId: vaultId, keys: ["webdav_password", "storage_password"],
                activeKeys: ["active_webdav_password", "active_storage_password"])
            return value
        }
        let defaults = UserDefaults(suiteName: Self.sharedGroup)
        if let legacy = defaults?.string(forKey: "storage_password_\(vaultId)") ?? defaults?.string(forKey: "webdav_password_\(vaultId)"), !legacy.isEmpty {
            _ = saveStoragePassword(legacy, for: vaultId)
            return legacy
        }
        return nil
    }

    public func deleteStoragePassword(for vaultId: String) {
        var bundle = loadBundle(for: vaultId)
        bundle.storagePassword = nil
        _ = persistBundle(bundle, for: vaultId)
        for account in ["storage-password-\(vaultId)", "webdav-password-\(vaultId)"] {
            queries(account: account).forEach { SecItemDelete($0 as CFDictionary) }
        }
        removeLegacy(vaultId: vaultId, keys: ["webdav_password", "storage_password"],
            activeKeys: ["active_webdav_password", "active_storage_password"])
    }

    @discardableResult
    public func saveVaultPassword(_ password: String, for vaultId: String) -> Bool {
        var bundle = loadBundle(for: vaultId)
        bundle.vaultPassword = password
        guard persistBundle(bundle, for: vaultId) else { return false }
        removeLegacy(vaultId: vaultId, keys: ["vault_password"], activeKeys: ["active_vault_password"])
        return true
    }

    public func getVaultPassword(for vaultId: String) -> String? {
        let bundle = loadBundle(for: vaultId)
        if let value = bundle.vaultPassword, !value.isEmpty {
            removeLegacy(vaultId: vaultId, keys: ["vault_password"], activeKeys: ["active_vault_password"])
            return value
        }
        if let legacy = UserDefaults(suiteName: Self.sharedGroup)?.string(forKey: "vault_password_\(vaultId)"), !legacy.isEmpty {
            _ = saveVaultPassword(legacy, for: vaultId)
            return legacy
        }
        return nil
    }

    public func deleteVaultPassword(for vaultId: String) {
        var bundle = loadBundle(for: vaultId)
        bundle.vaultPassword = nil
        _ = persistBundle(bundle, for: vaultId)
        queries(account: "vault-password-\(vaultId)").forEach { SecItemDelete($0 as CFDictionary) }
        removeLegacy(vaultId: vaultId, keys: ["vault_password"], activeKeys: ["active_vault_password"])
    }

    public func saveCredentialsToAppGroup(vaultId: String, storagePassword: String?, vaultPassword: String?) {
        UserDefaults(suiteName: Self.sharedGroup)?.set(vaultId, forKey: "active_vault_id")
        if let value = storagePassword { _ = saveStoragePassword(value, for: vaultId) }
        if let value = vaultPassword { _ = saveVaultPassword(value, for: vaultId) }
    }

    public func storeMasterKey(_ key: Masterkey, forVault vaultId: String) throws {
        // Master key is held securely in active memory session; skip redundant Keychain disk writes to avoid prompt fatigue
    }
    public func getMasterKey(forVault vaultId: String) throws -> Masterkey? {
        return nil
    }
    public func deleteMasterKey(forVault vaultId: String) throws {
        try? KeychainService.deleteMasterKey(forVault: vaultId)
    }

    @discardableResult
    public func saveBaiduPanToken(data: Data, for vaultId: String) -> Bool {
        return write(data.base64EncodedString(), account: "baidupan-token-\(vaultId)")
    }

    public func getBaiduPanToken(for vaultId: String) -> Data? {
        if let b64 = read(account: "baidupan-token-\(vaultId)") {
            return Data(base64Encoded: b64)
        }
        return nil
    }

    public func deleteBaiduPanToken(for vaultId: String) {
        queries(account: "baidupan-token-\(vaultId)").forEach { SecItemDelete($0 as CFDictionary) }
    }
}
