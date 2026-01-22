//
//  KeychainService.swift
//  CloudDriveCore
//
//  密钥链服务，用于在主应用和FileProviderExtension之间共享主密钥
//

import Foundation
import Security
import CryptoKit

class KeychainService {
    // 共享组标识符，需要与App Group一致
    private static let sharedGroup = "group.net.aabg.CloudDrive"
    
    // 密钥链访问控制策略
    private static let accessControl = SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        .applicationPassword,
        nil
    )
    
    // 存储主密钥到密钥链
    static func storeMasterKey(_ key: SymmetricKey, forVault vaultId: String) throws {
        // 将SymmetricKey转换为Data
        let keyData = Data(key.withUnsafeBytes { Array($0) })
        
        // 准备查询
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "masterKey_\(vaultId)",
            kSecAttrAccessGroup as String: sharedGroup,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse
        ]
        
        // 先删除旧密钥（如果存在）
        SecItemDelete(query as CFDictionary)
        
        // 添加新密钥
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "CloudDrive", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to store master key in keychain"])
        }
        
        print("✅ Keychain: 主密钥已存储到密钥链，保险库ID: \(vaultId)")
    }
    
    // 从密钥链获取主密钥
    static func getMasterKey(forVault vaultId: String) throws -> SymmetricKey? {
        // 准备查询
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "masterKey_\(vaultId)",
            kSecAttrAccessGroup as String: sharedGroup,
            kSecReturnData as String: kCFBooleanTrue,
            kSecAttrSynchronizable as String: kCFBooleanFalse
        ]
        
        // 执行查询
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                print("ℹ️ Keychain: 未找到主密钥，保险库ID: \(vaultId)")
                return nil
            }
            throw NSError(domain: "CloudDrive", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to retrieve master key from keychain"])
        }
        
        // 转换为Data
        guard let keyData = item as? Data else {
            throw NSError(domain: "CloudDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid master key data in keychain"])
        }
        
        // 转换为SymmetricKey
        let key = SymmetricKey(data: keyData)
        print("✅ Keychain: 已从密钥链获取主密钥，保险库ID: \(vaultId)")
        return key
    }
    
    // 从密钥链删除主密钥
    static func deleteMasterKey(forVault vaultId: String) throws {
        // 准备查询
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "masterKey_\(vaultId)",
            kSecAttrAccessGroup as String: sharedGroup,
            kSecAttrSynchronizable as String: kCFBooleanFalse
        ]
        
        // 删除密钥
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: "CloudDrive", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to delete master key from keychain"])
        }
        
        print("✅ Keychain: 主密钥已从密钥链删除，保险库ID: \(vaultId)")
    }
}
