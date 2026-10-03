import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit
import UniformTypeIdentifiers

extension S3StorageClient {
    public func move(from sourcePath: String, to destinationPath: String) async throws {
        try await move(from: sourcePath, to: destinationPath, expectedETag: nil)
    }
    
    public func move(from sourcePath: String, to destinationPath: String, expectedETag: String?) async throws {
        let srcKey = resolveKey(sourcePath)
        let dstKey = resolveKey(destinationPath)
        if srcKey == dstKey { return }
        
        if let expected = expectedETag {
            let (srcURL, srcHost) = try buildURL(key: srcKey)
            var headReq = URLRequest(url: srcURL)
            headReq.httpMethod = "HEAD"
            signRequest(&headReq, host: srcHost)
            let (_, headResp) = try await session.data(for: headReq)
            if let http = headResp as? HTTPURLResponse {
                let remoteETag = http.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                guard remoteETag == expected else {
                    throw StorageError.serverError(statusCode: 412, message: "Precondition Failed: expected ETag \(expected), got \(remoteETag ?? "none")")
                }
            }
        }
        
        // 检查源是否含有子对象（目录移动）
        var subKeysToMove: [String] = []
        var continuationToken: String? = nil
        repeat {
            var query = [
                URLQueryItem(name: "list-type", value: "2"),
                URLQueryItem(name: "prefix", value: srcKey + "/")
            ]
            if let token = continuationToken, !token.isEmpty {
                query.append(URLQueryItem(name: "continuation-token", value: token))
            }
            let (listURL, listHost) = try buildURL(key: "", queryItems: query)
            var listReq = URLRequest(url: listURL)
            listReq.httpMethod = "GET"
            signRequest(&listReq, host: listHost)
            if let (data, resp) = try? await session.data(for: listReq),
               let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                let page = parseS3ListObjectsV2Page(xmlData: data, prefix: srcKey + "/")
                for r in page.resources {
                    let k = resolveKey(r.path)
                    if !k.isEmpty { subKeysToMove.append(k) }
                }
                continuationToken = (page.isTruncated ? page.nextContinuationToken : nil)
            } else {
                continuationToken = nil
            }
        } while continuationToken != nil
        
        if !subKeysToMove.isEmpty {
            // 目录移动：递归移动所有子对象
            for oldKey in subKeysToMove {
                let relative = String(oldKey.dropFirst(srcKey.count))
                let newKey = dstKey + relative
                
                let (dstURL, dstHost) = try buildURL(key: newKey)
                var copyReq = URLRequest(url: dstURL)
                copyReq.httpMethod = "PUT"
                let encodedSrc = "/\(config.bucket)/\(oldKey)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "/\(config.bucket)/\(oldKey)"
                copyReq.setValue(encodedSrc, forHTTPHeaderField: "x-amz-copy-source")
                let empty = Data()
                signRequest(&copyReq, host: dstHost, payloadData: empty)
                copyReq.httpBody = empty
                
                let (data, resp) = try await session.data(for: copyReq)
                guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    let msg = String(data: data, encoding: .utf8) ?? "Copy subkey failed: \(oldKey)"
                    throw StorageError.serverError(statusCode: (resp as? HTTPURLResponse)?.statusCode ?? 500, message: msg)
                }
                
                let (oldURL, oldHost) = try buildURL(key: oldKey)
                var del = URLRequest(url: oldURL)
                del.httpMethod = "DELETE"
                signRequest(&del, host: oldHost)
                _ = try? await session.data(for: del)
            }
        }
        
        // S3 拷贝对象: PUT dstKey, x-amz-copy-source: /bucket/srcKey
        let (dstURL, dstHost) = try buildURL(key: dstKey)
        var copyReq = URLRequest(url: dstURL)
        copyReq.httpMethod = "PUT"
        
        let encodedSrc = "/\(config.bucket)/\(srcKey)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "/\(config.bucket)/\(srcKey)"
        copyReq.setValue(encodedSrc, forHTTPHeaderField: "x-amz-copy-source")
        
        let empty = Data()
        signRequest(&copyReq, host: dstHost, payloadData: empty)
        copyReq.httpBody = empty
        
        let (data, resp) = try await session.data(for: copyReq)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) && subKeysToMove.isEmpty {
            let msg = String(data: data, encoding: .utf8) ?? "Copy failed"
            throw StorageError.serverError(statusCode: (resp as? HTTPURLResponse)?.statusCode ?? 500, message: msg)
        }
        
        // 删除源文件
        try await delete(path: sourcePath)
    }
}
