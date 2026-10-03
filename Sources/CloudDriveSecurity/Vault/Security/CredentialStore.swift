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
            if status == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = data
                if query[kSecUseDataProtectionKeychain as String] != nil {
                    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                }
                if SecItemAdd(add as CFDictionary, nil) == errSecSuccess { return true }
            }
        }
        Logger.shared.error(.system, "CredentialStore: Could not persist credential in Keychain")
        return false
    }

    private func removeLegacy(vaultId: String, keys: [String], activeKeys: [String]) {
        guard let defaults = UserDefaults(suiteName: Self.sharedGroup) else { return }
        keys.forEach { defaults.removeObject(forKey: "\($0)_\(vaultId)") }
        if defaults.string(forKey: "active_vault_id") == vaultId {
            activeKeys.forEach { defaults.removeObject(forKey: $0) }
        }
    }

    @discardableResult
    public func saveStoragePassword(_ password: String, for vaultId: String) -> Bool {
        guard write(password, account: "storage-password-\(vaultId)") else { return false }
        removeLegacy(vaultId: vaultId, keys: ["webdav_password", "storage_password"],
            activeKeys: ["active_webdav_password", "active_storage_password"])
        return true
    }

    public func getStoragePassword(for vaultId: String) -> String? {
        if let value = read(account: "storage-password-\(vaultId)") ?? read(account: "webdav-password-\(vaultId)") {
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
        for account in ["storage-password-\(vaultId)", "webdav-password-\(vaultId)"] {
            queries(account: account).forEach { SecItemDelete($0 as CFDictionary) }
        }
        removeLegacy(vaultId: vaultId, keys: ["webdav_password", "storage_password"],
            activeKeys: ["active_webdav_password", "active_storage_password"])
    }

    @discardableResult
    public func saveVaultPassword(_ password: String, for vaultId: String) -> Bool {
        guard write(password, account: "vault-password-\(vaultId)") else { return false }
        removeLegacy(vaultId: vaultId, keys: ["vault_password"], activeKeys: ["active_vault_password"])
        return true
    }

    public func getVaultPassword(for vaultId: String) -> String? {
        if let value = read(account: "vault-password-\(vaultId)") {
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
        queries(account: "vault-password-\(vaultId)").forEach { SecItemDelete($0 as CFDictionary) }
        removeLegacy(vaultId: vaultId, keys: ["vault_password"], activeKeys: ["active_vault_password"])
    }

    public func saveCredentialsToAppGroup(vaultId: String, storagePassword: String?, vaultPassword: String?) {
        UserDefaults(suiteName: Self.sharedGroup)?.set(vaultId, forKey: "active_vault_id")
        if let value = storagePassword { _ = saveStoragePassword(value, for: vaultId) }
        if let value = vaultPassword { _ = saveVaultPassword(value, for: vaultId) }
    }

    public func storeMasterKey(_ key: Masterkey, forVault vaultId: String) throws { try KeychainService.storeMasterKey(key, forVault: vaultId) }
    public func getMasterKey(forVault vaultId: String) throws -> Masterkey? { try KeychainService.getMasterKey(forVault: vaultId) }
    public func deleteMasterKey(forVault vaultId: String) throws { try KeychainService.deleteMasterKey(forVault: vaultId) }
}
