import CloudDriveContracts
import CloudDriveSupport
//
//  CryptomatorVaultConfig.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  Cryptomator 官方标准 Format 8 配置文件 (vault.cryptomator) JWT 生成与解析
//

import Foundation
import CommonCrypto
import CryptomatorCryptoLib

public struct CryptomatorVaultConfig: Codable {
    public struct Header: Codable {
        public let kid: String
        public let typ: String
        public let alg: String
        
        public init(kid: String = "masterkeyfile:masterkey.cryptomator", typ: String = "JWT", alg: String = "HS256") {
            self.kid = kid
            self.typ = typ
            self.alg = alg
        }
    }
    
    public struct Payload: Codable {
        public let format: Int
        public let shorteningThreshold: Int
        public let jti: String
        public let cipherCombo: String
        
        public init(
            format: Int = 8,
            shorteningThreshold: Int = 220,
            jti: String = UUID().uuidString.lowercased(),
            cipherCombo: String = "SIV_GCM"
        ) {
            self.format = format
            self.shorteningThreshold = shorteningThreshold
            self.jti = jti
            self.cipherCombo = cipherCombo
        }
    }
    
    public let header: Header
    public let payload: Payload
    public let rawJWT: String
    
    public init(header: Header, payload: Payload, rawJWT: String) {
        self.header = header
        self.payload = payload
        self.rawJWT = rawJWT
    }
    
    // MARK: - Factory & Parsing
    
    /// 生成符合 Cryptomator Format 8 规范的标准 vault.cryptomator JWT 配置并使用 512 位 rawKey 签名
    public static func create(
        masterKey: Masterkey,
        cipherCombo: String = "SIV_GCM",
        shorteningThreshold: Int = 220
    ) throws -> (config: CryptomatorVaultConfig, jwtData: Data) {
        let header = Header()
        let payload = Payload(format: 8, shorteningThreshold: shorteningThreshold, jti: UUID().uuidString.lowercased(), cipherCombo: cipherCombo)
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        let headerData = try encoder.encode(header)
        let payloadData = try encoder.encode(payload)
        
        let encHeader = base64UrlEncode(headerData)
        let encPayload = base64UrlEncode(payloadData)
        let signingInput = "\(encHeader).\(encPayload)"
        
        let rawKeyData = Data(masterKey.rawKey)
        let signature = hmac(key: rawKeyData, data: signingInput.data(using: .utf8)!, algorithm: header.alg)
        let encSignature = base64UrlEncode(signature)
        
        let jwt = "\(signingInput).\(encSignature)"
        guard let jwtData = jwt.data(using: .utf8) else {
            throw CryptomatorError.corruptedVault
        }
        
        let config = CryptomatorVaultConfig(header: header, payload: payload, rawJWT: jwt)
        return (config, jwtData)
    }
    
    /// 解析 vault.cryptomator 的 JWT 头部与载荷（未验证签名，用于先提取 kid 和 cipherCombo）
    public static func decodeUnverified(jwtString: String) throws -> CryptomatorVaultConfig {
        let trimmed = jwtString.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.components(separatedBy: ".")
        guard parts.count == 3 else {
            throw CryptomatorError.corruptedVault
        }
        
        guard let headerData = base64UrlDecode(parts[0]),
              let payloadData = base64UrlDecode(parts[1]) else {
            throw CryptomatorError.corruptedVault
        }
        
        let header = try JSONDecoder().decode(Header.self, from: headerData)
        let payload = try JSONDecoder().decode(Payload.self, from: payloadData)
        
        guard ["HS256", "HS384", "HS512"].contains(header.alg), header.typ == "JWT",
              header.kid.hasPrefix("masterkeyfile:"), payload.format == 8,
              ["SIV_GCM", "SIV_CTRMAC"].contains(payload.cipherCombo),
              payload.shorteningThreshold > 0 else { throw CryptomatorError.corruptedVault }
        let masterkeyPath = String(header.kid.dropFirst("masterkeyfile:".count))
        guard !masterkeyPath.isEmpty, !masterkeyPath.hasPrefix("/"),
              !masterkeyPath.split(separator: "/").contains(".."),
              !masterkeyPath.contains("\\") else { throw CryptomatorError.corruptedVault }
        return CryptomatorVaultConfig(header: header, payload: payload, rawJWT: trimmed)
    }
    
    /// 使用解锁后的 Masterkey 512 位 rawKey 验证 JWT 签名的完整性
    public func verifySignature(masterKey: Masterkey) -> Bool {
        let parts = rawJWT.components(separatedBy: ".")
        guard parts.count == 3, ["HS256", "HS384", "HS512"].contains(header.alg),
              let actualSignature = Self.base64UrlDecode(parts[2]) else { return false }
        
        let signingInput = "\(parts[0]).\(parts[1])"
        let rawKeyData = Data(masterKey.rawKey)
        let expectedSignature = CryptomatorVaultConfig.hmac(key: rawKeyData, data: signingInput.data(using: .utf8)!, algorithm: header.alg)
        guard actualSignature.count == expectedSignature.count else { return false }
        var difference: UInt8 = 0
        for (actual, expected) in zip(actualSignature, expectedSignature) { difference |= actual ^ expected }
        return difference == 0
    }
    
    // MARK: - Crypto & Encoding Utilities
    
    public static func base64UrlEncode(_ data: Data) -> String {
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
    
    public static func base64UrlDecode(_ str: String) -> Data? {
        var b64 = str.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 {
            b64.append("=")
        }
        return Data(base64Encoded: b64)
    }
    
    public static func hmac(key: Data, data: Data, algorithm: String) -> Data {
        let ccalg: CCHmacAlgorithm
        let digestLen: Int
        switch algorithm {
        case "HS384":
            ccalg = CCHmacAlgorithm(kCCHmacAlgSHA384)
            digestLen = Int(CC_SHA384_DIGEST_LENGTH)
        case "HS512":
            ccalg = CCHmacAlgorithm(kCCHmacAlgSHA512)
            digestLen = Int(CC_SHA512_DIGEST_LENGTH)
        default: // HS256
            ccalg = CCHmacAlgorithm(kCCHmacAlgSHA256)
            digestLen = Int(CC_SHA256_DIGEST_LENGTH)
        }
        
        var mac = [UInt8](repeating: 0, count: digestLen)
        data.withUnsafeBytes { dataBytes in
            key.withUnsafeBytes { keyBytes in
                CCHmac(ccalg, keyBytes.baseAddress, key.count, dataBytes.baseAddress, data.count, &mac)
            }
        }
        return Data(mac)
    }
}
