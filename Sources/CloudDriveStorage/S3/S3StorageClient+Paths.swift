import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit
import UniformTypeIdentifiers

extension S3StorageClient {
    // MARK: - Key & URL Resolution
    
    /// 将 VFS 逻辑路径转换为 S3 Key
    func resolveKey(_ path: String, isDirectory: Bool = false) -> String {
        var clean = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !config.rootPrefix.isEmpty {
            let prefixClean = config.rootPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if clean.isEmpty {
                clean = prefixClean
            } else {
                clean = "\(prefixClean)/\(clean)"
            }
        }
        if isDirectory && !clean.isEmpty && !clean.hasSuffix("/") {
            clean += "/"
        }
        return clean
    }
    
    /// 构造请求 URL (支持 Path-Style 与 Virtual-Hosted Style)
    func buildURL(key: String, queryItems: [URLQueryItem] = []) throws -> (URL, String) {
        var endpointStr = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !endpointStr.hasPrefix("http://") && !endpointStr.hasPrefix("https://") {
            endpointStr = "https://\(endpointStr)"
        }
        guard let base = URL(string: endpointStr) else {
            throw StorageError.invalidOperation
        }
        
        let host: String
        let path: String
        let scheme = base.scheme ?? "https"
        let portPart = base.port != nil ? ":\(base.port!)" : ""
        
        if config.usePathStyle || base.host == "localhost" || (base.host?.contains("127.0.0.1") == true) {
            // Path-style: http://endpoint:port/bucket/key
            host = "\(base.host ?? "")\(portPart)"
            let encodedBucket = config.bucket.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? config.bucket
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
            path = encodedKey.isEmpty ? "/\(encodedBucket)" : "/\(encodedBucket)/\(encodedKey)"
        } else {
            // Virtual-hosted style: http://bucket.endpoint:port/key
            host = "\(config.bucket).\(base.host ?? "")\(portPart)"
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
            path = encodedKey.isEmpty ? "/" : (encodedKey.hasPrefix("/") ? encodedKey : "/\(encodedKey)")
        }
        
        var comp = URLComponents()
        comp.scheme = scheme
        comp.host = base.host
        comp.port = base.port
        if !config.usePathStyle && base.host != "localhost" && (base.host?.contains("127.0.0.1") != true) {
            comp.host = "\(config.bucket).\(base.host ?? "")"
        }
        comp.percentEncodedPath = path
        if !queryItems.isEmpty {
            comp.queryItems = queryItems
        }
        
        guard let url = comp.url else {
            throw StorageError.invalidOperation
        }
        return (url, host)
    }
}
