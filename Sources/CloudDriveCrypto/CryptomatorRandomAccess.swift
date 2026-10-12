//
//  CryptomatorRandomAccess.swift
//  CloudDriveCrypto
//
//  32KB 分块随机解密与 Range 读取支持 (Format 7/8 SIV-GCM)
//

import Foundation
import CryptoKit
import CryptomatorCryptoLib

public struct CryptomatorDecryptedHeader {
    public let headerNonce: Data
    public let contentKey: Data
}

public enum CryptomatorRandomAccess {
    public static let cleartextChunkSize: Int64 = 32 * 1024 // 32,768 bytes
    public static let nonceSize: Int = 12
    public static let tagSize: Int = 16
    public static let headerSize: Int64 = 68 // 12 + (8 + 32) + 16
    public static let ciphertextChunkOverhead: Int64 = Int64(nonceSize + tagSize) // 28 bytes
    public static let fullCiphertextChunkSize: Int64 = cleartextChunkSize + ciphertextChunkOverhead // 32,796 bytes

    /// 解密 68 字节的文件头，提取 headerNonce 和 32 字节的 contentKey
    public static func decryptHeader(headerData: Data, masterkey: Masterkey) throws -> CryptomatorDecryptedHeader {
        guard headerData.count >= Int(headerSize) else {
            throw CryptoError.invalidParameter("Header data too small (\(headerData.count) < \(headerSize))")
        }
        let rawHeader = headerData.prefix(Int(headerSize))
        let headerNonce = rawHeader.prefix(nonceSize)
        
        let rawKey = masterkey.rawKey
        guard rawKey.count >= 32 else {
            throw CryptoError.invalidParameter("Masterkey rawKey too small")
        }
        let aesMasterKey = Array(rawKey[0..<32])
        
        let box = try AES.GCM.SealedBox(combined: rawHeader)
        let decrypted = try AES.GCM.open(box, using: SymmetricKey(data: aesMasterKey), authenticating: Data())
        
        guard decrypted.count >= 40 else {
            throw CryptoError.invalidParameter("Decrypted header payload too small")
        }
        // 前 8 字节为 legacy 填充 (0xFF)，后 32 字节为 contentKey
        let contentKey = decrypted.subdata(in: 8..<40)
        return CryptomatorDecryptedHeader(headerNonce: Data(headerNonce), contentKey: contentKey)
    }

    /// 解密单个 32KB 分块
    public static func decryptChunk(
        chunkCiphertext: Data,
        chunkIndex: UInt64,
        header: CryptomatorDecryptedHeader
    ) throws -> Data {
        guard chunkCiphertext.count >= (nonceSize + tagSize) else {
            throw CryptoError.invalidParameter("Ciphertext chunk too small (\(chunkCiphertext.count) bytes)")
        }
        
        var chunkNumBE = chunkIndex.bigEndian
        var ad = withUnsafeBytes(of: &chunkNumBE) { Data($0) }
        ad.append(header.headerNonce)
        
        let box = try AES.GCM.SealedBox(combined: chunkCiphertext)
        let cleartext = try AES.GCM.open(box, using: SymmetricKey(data: header.contentKey), authenticating: ad)
        return cleartext
    }

    /// 计算给定明文范围覆盖的分块序号范围 [startChunk, endChunk]
    public static func chunkRange(forCleartextRange range: ClosedRange<Int64>) -> (startChunk: Int64, endChunk: Int64) {
        let start = max(0, range.lowerBound)
        let end = max(start, range.upperBound)
        return (start / cleartextChunkSize, end / cleartextChunkSize)
    }

    /// 计算给定分块序号在密文文件中的字节偏移范围
    public static func ciphertextRange(forChunkIndex chunkIndex: Int64, totalCiphertextSize: Int64? = nil) -> ClosedRange<Int64> {
        let start = headerSize + chunkIndex * fullCiphertextChunkSize
        let theoreticalEnd = start + fullCiphertextChunkSize - 1
        if let total = totalCiphertextSize, total > start {
            return start...min(theoreticalEnd, total - 1)
        }
        return start...theoreticalEnd
    }

    /// 计算覆盖连续分块 [startChunk, endChunk] 的整段密文字节范围
    public static func contiguousCiphertextRange(
        startChunk: Int64,
        endChunk: Int64,
        totalCiphertextSize: Int64? = nil
    ) -> ClosedRange<Int64> {
        let start = headerSize + startChunk * fullCiphertextChunkSize
        let theoreticalEnd = headerSize + (endChunk + 1) * fullCiphertextChunkSize - 1
        if let total = totalCiphertextSize, total > start {
            return start...min(theoreticalEnd, total - 1)
        }
        return start...theoreticalEnd
    }

    /// 根据明文大小精确计算对应的密文文件大小 (包含 68 字节文件头及每分块 28 字节开销)
    public static func calculateCiphertextSize(cleartextSize: Int64) -> Int64 {
        if cleartextSize <= 0 {
            return headerSize
        }
        let fullChunks = cleartextSize / cleartextChunkSize
        let remainder = cleartextSize % cleartextChunkSize
        var total = headerSize + fullChunks * fullCiphertextChunkSize
        if remainder > 0 {
            total += (remainder + ciphertextChunkOverhead)
        }
        return total
    }
}
