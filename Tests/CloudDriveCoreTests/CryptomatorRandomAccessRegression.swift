//
//  CryptomatorRandomAccessRegression.swift
//  CloudDriveTestsRunner
//
//  32KB 分块随机解密与 Range 局部读取完整回归测试套件
//

import Foundation
import CryptoKit
import CryptomatorCryptoLib
import CloudDriveCore
import CloudDriveCrypto
import CloudDriveStorage
import CloudDriveVaultFormat

func runCryptomatorRandomAccessRegressionTests() async throws {
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("🧪 Running Cryptomator Random-Access & Partial Range Regressions")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    
    var passed = 0
    var failed = 0
    
    func assert(_ condition: Bool, _ name: String) {
        if condition {
            print("  ✅ PASS: \(name)")
            passed += 1
        } else {
            print("  ❌ FAIL: \(name)")
            failed += 1
        }
    }
    
    // 1. 测试基础分块计算数学
    do {
        print("\n--- 1. Testing Chunk Math Calculations ---")
        let range1 = CryptomatorRandomAccess.chunkRange(forCleartextRange: 0...10)
        assert(range1.startChunk == 0 && range1.endChunk == 0, "Range 0...10 belongs to chunk (0, 0)")
        
        let rangeCross = CryptomatorRandomAccess.chunkRange(forCleartextRange: 32760...32780)
        assert(rangeCross.startChunk == 0 && rangeCross.endChunk == 1, "Boundary range 32760...32780 crosses chunk (0, 1)")
        
        let rangeFar = CryptomatorRandomAccess.chunkRange(forCleartextRange: 70000...100000)
        assert(rangeFar.startChunk == 2 && rangeFar.endChunk == 3, "Range 70000...100000 belongs to chunk (2, 3)")
        
        let cipherRange0 = CryptomatorRandomAccess.ciphertextRange(forChunkIndex: 0)
        assert(cipherRange0.lowerBound == 68 && cipherRange0.upperBound == 68 + 32796 - 1, "Ciphertext range for chunk 0 starts at 68 with length 32796")
        
        let cipherRange1 = CryptomatorRandomAccess.ciphertextRange(forChunkIndex: 1)
        assert(cipherRange1.lowerBound == 68 + 32796, "Ciphertext range for chunk 1 starts at 68 + 32796")
    }
    
    // 2. 测试 32KB 分块随机解密 (Header + Chunk Decryption)
    do {
        print("\n--- 2. Testing 32KB Block Decryption Integrity ---")
        let encryption = VFSEncryption()
        let (masterKey, _) = try encryption.generateMasterKey(password: "TestRandomAccess123!@#")
        
        // 创建 100,000 字节的结构化测试明文（跨 4 个 32KB 分块）
        var originalData = Data()
        for i in 0..<100_000 {
            originalData.append(UInt8(i % 251))
        }
        
        // 使用官方标准 Cryptor 加密
        let tempClearURL = FileManager.default.temporaryDirectory.appendingPathComponent("ra_clear_\(UUID().uuidString)")
        let tempCipherURL = FileManager.default.temporaryDirectory.appendingPathComponent("ra_cipher_\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempClearURL)
            try? FileManager.default.removeItem(at: tempCipherURL)
        }
        try originalData.write(to: tempClearURL)
        try encryption.encryptFile(from: tempClearURL, to: tempCipherURL, key: masterKey)
        
        let ciphertextData = try Data(contentsOf: tempCipherURL)
        assert(ciphertextData.count > 100_000, "Ciphertext file generated with proper overhead")
        
        // 验证文件头解密
        let headerData = ciphertextData.prefix(68)
        let decryptedHeader = try CryptomatorRandomAccess.decryptHeader(headerData: headerData, masterkey: masterKey)
        assert(decryptedHeader.headerNonce.count == 12, "Decrypted header nonce length is 12 bytes")
        assert(decryptedHeader.contentKey.count == 32, "Decrypted content key length is 32 bytes")
        
        // 解密 Chunk 0 并比对明文
        let chunk0Cipher = ciphertextData.subdata(in: 68..<(68 + 32796))
        let chunk0Clear = try CryptomatorRandomAccess.decryptChunk(chunkCiphertext: chunk0Cipher, chunkIndex: 0, header: decryptedHeader)
        assert(chunk0Clear == originalData.subdata(in: 0..<32768), "Chunk 0 decrypted plaintext matches original bytes exactly")
        
        // 解密 Chunk 1 并比对明文
        let chunk1Cipher = ciphertextData.subdata(in: (68 + 32796)..<(68 + 2 * 32796))
        let chunk1Clear = try CryptomatorRandomAccess.decryptChunk(chunkCiphertext: chunk1Cipher, chunkIndex: 1, header: decryptedHeader)
        assert(chunk1Clear == originalData.subdata(in: 32768..<65536), "Chunk 1 decrypted plaintext matches original bytes exactly")
        
        // 解密 Chunk 3（末尾非完整块）
        let chunk3Start = 68 + 3 * 32796
        let chunk3Cipher = ciphertextData.subdata(in: chunk3Start..<ciphertextData.count)
        let chunk3Clear = try CryptomatorRandomAccess.decryptChunk(chunkCiphertext: chunk3Cipher, chunkIndex: 3, header: decryptedHeader)
        assert(chunk3Clear == originalData.subdata(in: 98304..<100_000), "Chunk 3 (trailing partial chunk) decrypted plaintext matches exactly")
    }
    
    // 3. 测试 CryptomatorFormat.readCleartextRange 端到端局部读取
    do {
        print("\n--- 3. Testing CryptomatorFormat.readCleartextRange ---")
        let encryption = VFSEncryption()
        let (masterKey, _) = try encryption.generateMasterKey(password: "FormatRandomAccess123!@#")
        
        var originalData = Data()
        for i in 0..<120_000 {
            originalData.append(UInt8((i * 7 + 13) % 256))
        }
        
        let tempStorageDir = FileManager.default.temporaryDirectory.appendingPathComponent("storage_ra_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempStorageDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempStorageDir) }
        
        let localClient = LocalStorageClient()
        let format = CryptomatorFormat(masterkey: masterKey, storageClient: localClient, basePath: tempStorageDir.path)
        
        // 创建明文源并加密到存储目录
        let sourcePlainURL = tempStorageDir.appendingPathComponent("source.bin")
        let remoteCipherURL = tempStorageDir.appendingPathComponent("encrypted.c9r")
        try originalData.write(to: sourcePlainURL)
        try encryption.encryptFile(from: sourcePlainURL, to: remoteCipherURL, key: masterKey)
        
        // 场景 A: 读取头部前 20 字节
        let headBytes = try await format.readCleartextRange(remotePath: remoteCipherURL.path, cleartextRange: 0...19)
        assert(headBytes == originalData.subdata(in: 0..<20), "Read range 0...19 matches original start")
        
        // 场景 B: 读取单分块内部片段 (1024...2048)
        let midBytes = try await format.readCleartextRange(remotePath: remoteCipherURL.path, cleartextRange: 1024...2048)
        assert(midBytes == originalData.subdata(in: 1024..<2049), "Read range 1024...2048 within chunk 0 matches")
        
        // 场景 C: 跨分块边界读取 (32750...32800, 跨越 Chunk 0 与 Chunk 1)
        let crossBytes = try await format.readCleartextRange(remotePath: remoteCipherURL.path, cleartextRange: 32750...32800)
        assert(crossBytes == originalData.subdata(in: 32750..<32801), "Read range crossing chunk boundary 32750...32800 matches seamlessly")
        
        // 场景 D: 大范围多块跨越读取 (30000...70000, 跨越 Chunk 0, 1, 2)
        let multiChunkBytes = try await format.readCleartextRange(remotePath: remoteCipherURL.path, cleartextRange: 30000...70000)
        assert(multiChunkBytes == originalData.subdata(in: 30000..<70001), "Read range crossing multiple chunks 30000...70000 matches all bytes")
        
        // 场景 E: 文件末尾精确读取 (119900...119999)
        let tailBytes = try await format.readCleartextRange(remotePath: remoteCipherURL.path, cleartextRange: 119900...119999)
        assert(tailBytes == originalData.subdata(in: 119900..<120000), "Read tail range 119900...119999 matches trailing bytes")
    }
    
    // 4. 测试 StorageClient.downloadRange
    do {
        print("\n--- 4. Testing StorageClient.downloadRange ---")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("storage_range_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let client = LocalStorageClient()
        let sampleFile = tempDir.appendingPathComponent("sample.txt")
        let sampleContent = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        try sampleContent.write(to: sampleFile, atomically: true, encoding: .utf8)
        
        let slice = try await client.downloadRange(path: sampleFile.path, range: 10...35)
        let sliceString = String(data: slice, encoding: .utf8)
        assert(sliceString == "ABCDEFGHIJKLMNOPQRSTUVWXYZ", "downloadRange extracted exact byte slice 10...35")
    }
    
    print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    if failed == 0 {
        print("🎉 All Cryptomator Random-Access & Partial Range Regressions PASSED (\(passed) passed)")
    } else {
        print("❌ Cryptomator Random-Access Regressions FAILED (\(passed) passed, \(failed) failed)")
        throw NSError(domain: "CryptomatorRandomAccessRegression", code: 1, userInfo: nil)
    }
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
}
