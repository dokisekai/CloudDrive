import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit
import UniformTypeIdentifiers

extension S3StorageClient {
    public func delete(path: String) async throws {
        try await delete(path: path, expectedETag: nil)
    }
    
    public func delete(path: String, expectedETag: String?) async throws {
        let key = resolveKey(path)
        if key.isEmpty { return }
        
        if let expected = expectedETag {
            let (url, host) = try buildURL(key: key)
            var headReq = URLRequest(url: url)
            headReq.httpMethod = "HEAD"
            signRequest(&headReq, host: host)
            let (_, headResp) = try await session.data(for: headReq)
            if let http = headResp as? HTTPURLResponse {
                let remoteETag = http.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                guard remoteETag == expected else {
                    throw StorageError.serverError(statusCode: 412, message: "Precondition Failed: expected ETag \(expected), got \(remoteETag ?? "none")")
                }
            }
        }
        
        // 1. 删除对象本身
        let (url, host) = try buildURL(key: key)
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        signRequest(&req, host: host)
        let (delData1, resp1) = try await session.data(for: req)
        if let http1 = resp1 as? HTTPURLResponse, !(200...299).contains(http1.statusCode) && http1.statusCode != 404 {
            let msg = String(data: delData1, encoding: .utf8) ?? "HTTP \(http1.statusCode)"
            throw StorageError.serverError(statusCode: http1.statusCode, message: msg)
        }
        
        // 2. 删除目录标记 key/
        let (dirURL, dirHost) = try buildURL(key: key + "/")
        var dirReq = URLRequest(url: dirURL)
        dirReq.httpMethod = "DELETE"
        signRequest(&dirReq, host: dirHost)
        let (delData2, resp2) = try await session.data(for: dirReq)
        if let http2 = resp2 as? HTTPURLResponse, !(200...299).contains(http2.statusCode) && http2.statusCode != 404 {
            let msg = String(data: delData2, encoding: .utf8) ?? "HTTP \(http2.statusCode)"
            throw StorageError.serverError(statusCode: http2.statusCode, message: msg)
        }
        
        // 3. 如果是目录，清理其下所有子对象 (前缀匹配，全量分页循环并逐一校验结果)
        var subContinuationToken: String? = nil
        repeat {
            var query = [
                URLQueryItem(name: "list-type", value: "2"),
                URLQueryItem(name: "prefix", value: key + "/")
            ]
            if let token = subContinuationToken, !token.isEmpty {
                query.append(URLQueryItem(name: "continuation-token", value: token))
            }
            let (listURL, listHost) = try buildURL(key: "", queryItems: query)
            var listReq = URLRequest(url: listURL)
            listReq.httpMethod = "GET"
            signRequest(&listReq, host: listHost)
            
            let (listData, listResp) = try await session.data(for: listReq)
            guard let listHttp = listResp as? HTTPURLResponse, (200...299).contains(listHttp.statusCode) else {
                let msg = String(data: listData, encoding: .utf8) ?? "Failed to list directory contents for deletion"
                throw StorageError.serverError(statusCode: (listResp as? HTTPURLResponse)?.statusCode ?? 500, message: msg)
            }
            
            let page = parseS3ListObjectsV2Page(xmlData: listData, prefix: key + "/")
            for r in page.resources {
                let subKey = resolveKey(r.path)
                let (subURL, subHost) = try buildURL(key: subKey)
                var del = URLRequest(url: subURL)
                del.httpMethod = "DELETE"
                signRequest(&del, host: subHost)
                let (subData, subResp) = try await session.data(for: del)
                if let subHttp = subResp as? HTTPURLResponse, !(200...299).contains(subHttp.statusCode) && subHttp.statusCode != 404 {
                    let msg = String(data: subData, encoding: .utf8) ?? "Failed to delete subkey \(subKey)"
                    throw StorageError.serverError(statusCode: subHttp.statusCode, message: msg)
                }
            }
            
            if page.isTruncated, let next = page.nextContinuationToken, !next.isEmpty {
                subContinuationToken = next
            } else {
                subContinuationToken = nil
            }
        } while subContinuationToken != nil
    }
}
