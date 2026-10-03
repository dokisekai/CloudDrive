import CloudDriveContracts
import CloudDriveSupport
import Foundation
import Security
import CryptomatorCryptoLib

/// Shared Data Protection Keychain, with a legacy macOS Keychain fallback.
class KeychainService {
    private static func queries(for vaultId: String) -> [[String: Any]] {
        let legacy: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "masterKey_\(vaultId)"]
        var shared = legacy
        shared[kSecAttrService as String] = CredentialStore.serviceName
        shared[kSecUseDataProtectionKeychain as String] = true
        shared[kSecAttrAccessGroup as String] = CredentialStore.sharedGroup
        return [shared, legacy]
    }

    static func storeMasterKey(_ key: Masterkey, forVault vaultId: String) throws {
        let data = Data(key.rawKey)
        var lastStatus = errSecItemNotFound
        for query in queries(for: vaultId) {
            lastStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if lastStatus == errSecSuccess { return }
            if lastStatus == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = data
                if query[kSecUseDataProtectionKeychain as String] != nil {
                    add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                }
                lastStatus = SecItemAdd(add as CFDictionary, nil)
                if lastStatus == errSecSuccess { return }
            }
        }
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(lastStatus))
    }

    static func getMasterKey(forVault vaultId: String) throws -> Masterkey? {
        var lastStatus = errSecItemNotFound
        for var query in queries(for: vaultId) {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            lastStatus = SecItemCopyMatching(query as CFDictionary, &result)
            if lastStatus == errSecSuccess {
                guard let data = result as? Data, data.count == 64 else {
                    throw VFSError.fileOperationFailed("Invalid master key in Keychain")
                }
                return Masterkey.createFromRaw(rawKey: [UInt8](data))
            }
        }
        if lastStatus == errSecItemNotFound { return nil }
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(lastStatus))
    }

    static func deleteMasterKey(forVault vaultId: String) throws {
        var lastError: OSStatus?
        for query in queries(for: vaultId) {
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound { lastError = status }
        }
        if let lastError { throw NSError(domain: NSOSStatusErrorDomain, code: Int(lastError)) }
    }
}
