import CloudDriveContracts
import CloudDriveSupport
//
//  VFSEncryption.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  虚拟文件系统加密实现 (Powered by CryptomatorCryptoLib)
//

import Foundation
import CryptomatorCryptoLib

/// VFS 加密管理器 - 使用 Cryptomator 官方加密库
public class VFSEncryption {
    private var masterkey: Masterkey?
    private var cryptor: Cryptor?
    
    // 我们在此使用 SIV-GCM 方案作为 Cryptomator 默认格式
    private let scheme: CryptorScheme = .sivGcm
    
    public init() {}
    
    // MARK: - Key Management
    
    /// 生成新的主密钥 (Masterkey) 及其原始字节
    public func generateMasterKey(password: String) throws -> (key: Masterkey, raw: Data) {
        // 使用 CryptomatorCryptoLib 内置的工厂创建安全随机的 Masterkey
        let newMasterkey = try Masterkey.createNew()
        let rawData = Data(newMasterkey.rawKey)
        return (newMasterkey, rawData)
    }
    
    /// 派生主密钥 - 为了向后兼容我们的 Keychain 存储格式，如果我们在 Keychain 里存了 raw 字节，我们在这里恢复它
    public func deriveMasterKey(password: String, salt: Data) throws -> Masterkey {
        // 由于我们不再使用 PBKDF2 直接导出 AES 密钥，
        // 这一步对于我们自定义系统，如果是首次生成，会在 generateMasterKey 里完成。
        // 为了兼容现有接口，如果外部传入了 rawKey（作为 salt 传递，或者通过其他方式），
        // 我们可以直接从 rawKey 创建：
        guard salt.count == 64 else {
            throw VFSError.encryptionFailed
        }
        return Masterkey.createFromRaw(rawKey: [UInt8](salt))
    }
    
    /// 从原始字节加载 Masterkey
    public func loadMasterKey(raw: Data) throws -> Masterkey {
        guard raw.count == 64 else { // AES256 (32) + MAC256 (32)
            throw VFSError.encryptionFailed
        }
        return Masterkey.createFromRaw(rawKey: [UInt8](raw))
    }
    
    public func setMasterKey(_ key: Masterkey) {
        self.masterkey = key
        self.cryptor = Cryptor(masterkey: key, scheme: scheme)
    }
    
    public func clearMasterKey() {
        self.masterkey = nil
        self.cryptor = nil
    }
    
    public func getMasterKey() -> Masterkey? {
        return masterkey
    }
    
    // MARK: - File Content Encryption
    
    /// 加密文件内容
    public func encryptFileContent(data: Data, key: Masterkey) throws -> Data {
        let tempCryptor = Cryptor(masterkey: key, scheme: scheme)
        
        let cleartextURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ciphertextURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        
        try data.write(to: cleartextURL)
        defer {
            try? FileManager.default.removeItem(at: cleartextURL)
            try? FileManager.default.removeItem(at: ciphertextURL)
        }
        
        try tempCryptor.encryptContent(from: cleartextURL, to: ciphertextURL)
        return try Data(contentsOf: ciphertextURL)
    }
    
    /// 解密文件内容
    public func decryptFileContent(data: Data, key: Masterkey) throws -> Data {
        let tempCryptor = Cryptor(masterkey: key, scheme: scheme)
        
        let ciphertextURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cleartextURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        
        try data.write(to: ciphertextURL)
        defer {
            try? FileManager.default.removeItem(at: ciphertextURL)
            try? FileManager.default.removeItem(at: cleartextURL)
        }
        
        try tempCryptor.decryptContent(from: ciphertextURL, to: cleartextURL)
        return try Data(contentsOf: cleartextURL)
    }
    
    /// Directly stream decrypt from encrypted file to destination plaintext file (constant memory, avoiding OOM)
    public func decryptFile(from sourceCiphertextURL: URL, to destinationCleartextURL: URL, key: Masterkey) throws {
        let tempCryptor = Cryptor(masterkey: key, scheme: scheme)
        let parentDir = destinationCleartextURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        if FileManager.default.fileExists(atPath: destinationCleartextURL.path) {
            try? FileManager.default.removeItem(at: destinationCleartextURL)
        }
        try tempCryptor.decryptContent(from: sourceCiphertextURL, to: destinationCleartextURL)
    }
    
    /// Directly stream encrypt from plaintext file to destination ciphertext file (constant memory, avoiding OOM)
    public func encryptFile(from sourceCleartextURL: URL, to destinationCiphertextURL: URL, key: Masterkey) throws {
        let tempCryptor = Cryptor(masterkey: key, scheme: scheme)
        let parentDir = destinationCiphertextURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        if FileManager.default.fileExists(atPath: destinationCiphertextURL.path) {
            try? FileManager.default.removeItem(at: destinationCiphertextURL)
        }
        try tempCryptor.encryptContent(from: sourceCleartextURL, to: destinationCiphertextURL)
    }
    
    // MARK: - Filename Encryption
    
    /// 加密文件名
    public func encryptFilename(_ filename: String, dirId: String? = nil, key: Masterkey) throws -> String {
        let tempCryptor = Cryptor(masterkey: key, scheme: scheme)
        // Cryptomator 的 SIV-GCM 方案，文件名加密需要一个 dirId。
        // 如果没有提供 dirId，我们将使用一个静态默认的空 UUID，虽然不如真实的 Cryptomator 安全，但能确保在本系统的兼容性
        let defaultDirId = "00000000-0000-0000-0000-000000000000"
        let targetDirId = (dirId ?? defaultDirId).data(using: .utf8)!
        return try tempCryptor.encryptFileName(filename, dirId: targetDirId)
    }
    
    /// 加密目录 ID
    public func encryptDirectoryId(_ dirId: String, key: Masterkey) throws -> String {
        let tempCryptor = Cryptor(masterkey: key, scheme: scheme)
        // 目录 ID 本身加密不需要另一个 dirId
        let targetDirId = dirId.data(using: .utf8)!
        return try tempCryptor.encryptDirId(targetDirId)
    }
    
    // MARK: - Generic Encryption/Decryption
    
    /// 加密任意数据
    public func encrypt(data: Data, key: Masterkey) throws -> Data {
        return try encryptFileContent(data: data, key: key)
    }
    
    /// 解密任意数据
    public func decrypt(data: Data, key: Masterkey) throws -> Data {
        return try decryptFileContent(data: data, key: key)
    }
}