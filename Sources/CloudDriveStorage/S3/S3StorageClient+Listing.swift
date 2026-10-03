import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit
import UniformTypeIdentifiers

extension S3StorageClient {
    // MARK: - StorageClient Implementation
    
    public func exists(path: String) async throws -> Bool {
        let clean = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if clean.isEmpty { return true } // 根目录在逻辑上始终存在
        let key = resolveKey(path)
        if key.isEmpty { return true }
        
        // 1. 尝试直接 HEAD 对象
        do {
            let (url, host) = try buildURL(key: key)
            var req = URLRequest(url: url)
            req.httpMethod = "HEAD"
            signRequest(&req, host: host)
            let (_, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                return true
            }
        } catch {}
        
        // 2. 尝试作为目录检查 HEAD key/
        do {
            let (dirURL, host) = try buildURL(key: key + "/")
            var req = URLRequest(url: dirURL)
            req.httpMethod = "HEAD"
            signRequest(&req, host: host)
            let (_, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                return true
            }
        } catch {}
        
        // 3. 检查是否有以此为前缀的子对象
        let query = [
            URLQueryItem(name: "list-type", value: "2"),
            URLQueryItem(name: "prefix", value: key + "/"),
            URLQueryItem(name: "max-keys", value: "1")
        ]
        let (listURL, host) = try buildURL(key: "", queryItems: query)
        var req = URLRequest(url: listURL)
        req.httpMethod = "GET"
        signRequest(&req, host: host)
        
        if let (data, resp) = try? await session.data(for: req),
           let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
            let xml = String(data: data, encoding: .utf8) ?? ""
            return xml.contains("<Key>") || xml.contains("<CommonPrefixes>")
        }
        
        return false
    }
    
    public func listDirectory(path: String) async throws -> [StorageResource] {
        var prefix = resolveKey(path, isDirectory: true)
        if prefix == "/" { prefix = "" }
        
        var allResources: [StorageResource] = []
        var continuationToken: String? = nil
        
        repeat {
            var queryItems = [
                URLQueryItem(name: "list-type", value: "2"),
                URLQueryItem(name: "delimiter", value: "/")
            ]
            if !prefix.isEmpty {
                queryItems.append(URLQueryItem(name: "prefix", value: prefix))
            }
            if let token = continuationToken, !token.isEmpty {
                queryItems.append(URLQueryItem(name: "continuation-token", value: token))
            }
            
            let (url, host) = try buildURL(key: "", queryItems: queryItems)
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            signRequest(&req, host: host)
            
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw StorageError.networkError("Invalid response")
            }
            guard (200...299).contains(http.statusCode) else {
                let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                throw StorageError.serverError(statusCode: http.statusCode, message: msg)
            }
            
            let page = parseS3ListObjectsV2Page(xmlData: data, prefix: prefix)
            allResources.append(contentsOf: page.resources)
            
            if page.isTruncated, let next = page.nextContinuationToken, !next.isEmpty {
                continuationToken = next
            } else {
                continuationToken = nil
            }
        } while continuationToken != nil
        
        return allResources
    }
}
