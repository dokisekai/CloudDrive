//
//  VFSEncryption.swift
//  CloudDriveCore
//
//  虚拟文件系统加密实现
//

import Foundation
import CryptoKit

/// VFS 加密管理器
class VFSEncryption {
    private var masterKey: SymmetricKey?
    private let saltSize = 32
    private let iterations = 100000
    
    // MARK: - Key Management
    
    /// 生成主密钥
    func generateMasterKey(password: String) throws -> (key: SymmetricKey, salt: Data) {
        let salt = generateSalt()
        let key = try deriveMasterKey(password: password, salt: salt)
        return (key, salt)
    }
    
    /// 派生主密钥（使用自定义 PBKDF2 实现）
    func deriveMasterKey(password: String, salt: Data) throws -> SymmetricKey {
        guard let passwordData = password.data(using: .utf8) else {
            throw VFSError.encryptionFailed
        }
        
        // 使用自定义的 PBKDF2 实现
        let derivedKey = try pbkdf2(password: passwordData, salt: salt, iterations: iterations, keyLength: 32)
        
        return SymmetricKey(data: derivedKey)
    }
    
    /// PBKDF2 实现（使用 HMAC-SHA256）
    private func pbkdf2(password: Data, salt: Data, iterations: Int, keyLength: Int) throws -> Data {
        var derivedKey = Data()
        var blockIndex: UInt32 = 1
        
        while derivedKey.count < keyLength {
            var block = Data()
            var u = salt + withUnsafeBytes(of: blockIndex.bigEndian) { Data($0) }
            
            for _ in 0..<iterations {
                let hmac = HMAC<SHA256>.authenticationCode(for: u, using: SymmetricKey(data: password))
                u = Data(hmac)
                
                if block.isEmpty {
                    block = u
                } else {
                    block = Data(zip(block, u).map { $0 ^ $1 })
                }
            }
            
            derivedKey.append(block)
            blockIndex += 1
        }
        
        return derivedKey.prefix(keyLength)
    }
    
    func setMasterKey(_ key: SymmetricKey) {
        self.masterKey = key
    }
    
    func getMasterKey() -> SymmetricKey? {
        return masterKey
    }
    
    private func generateSalt() -> Data {
        var salt = Data(count: saltSize)
        _ = salt.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, saltSize, bytes.baseAddress!)
        }
        return salt
    }
    
    // MARK: - File Content Encryption
    
    /// 加密文件内容
    func encryptFileContent(data: Data, key: SymmetricKey) throws -> Data {
        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(data, using: key, nonce: nonce)
        
        // 格式: nonce (12 bytes) + ciphertext + tag (16 bytes)
        var result = Data()
        result.append(nonce.withUnsafeBytes { Data($0) })
        result.append(sealedBox.ciphertext)
        result.append(sealedBox.tag)
        
        return result
    }
    
    /// 解密文件内容
    func decryptFileContent(data: Data, key: SymmetricKey) throws -> Data {
        guard data.count >= 28 else { // 12 + 16
            throw VFSError.decryptionFailed
        }
        
        let nonceData = data[0..<12]
        let tagData = data[(data.count - 16)...]
        let ciphertext = data[12..<(data.count - 16)]
        
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tagData)
        
        return try AES.GCM.open(sealedBox, using: key)
    }
    
    // MARK: - Filename Encryption
    
    /// 加密文件名（使用确定性加密以支持查找）
    func encryptFilename(_ filename: String, key: SymmetricKey) throws -> String {
        guard let data = filename.data(using: .utf8) else {
            throw VFSError.encryptionFailed
        }
        
        // 使用 HMAC 作为确定性加密（相同输入总是产生相同输出）
        let hmac = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(hmac).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
    
    /// 加密目录 ID
    func encryptDirectoryId(_ dirId: String, key: SymmetricKey) throws -> String {
        return try encryptFilename(dirId, key: key)
    }
    
    // MARK: - Generic Encryption/Decryption
    
    /// 加密数据
    func encrypt(data: Data, key: SymmetricKey) throws -> Data {
        return try encryptFileContent(data: data, key: key)
    }
    
    /// 解密数据
    func decrypt(data: Data, key: SymmetricKey) throws -> Data {
        return try decryptFileContent(data: data, key: key)
    }
}