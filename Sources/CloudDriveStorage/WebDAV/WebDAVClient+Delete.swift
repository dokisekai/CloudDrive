import Foundation
import CloudDriveContracts
import CloudDriveSupport

extension WebDAVClient {
    public func delete(path: String) async throws {
        try await delete(path: path, expectedETag: nil)
    }

    /// 删除文件或目录（DELETE，支持版本约束）
    public func delete(path: String, expectedETag: String?) async throws {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("🗑️ WebDAV.delete: Starting delete operation")
        print("   Path: \(path)")
        if let expectedETag { print("   Expected ETag: \(expectedETag)") }
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        guard baseURL != nil else {
            print("❌ WebDAV: Client not configured")
            throw WebDAVError.notConfigured
        }
        
        let url = try buildURL(for: path)
        print("📡 WebDAV: Delete host: \(url.host ?? "")")
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30  // 30秒超时
        
        // 添加认证
        addAuthentication(to: &request)

        if let expectedETag = expectedETag {
            request.setValue(try WebDAVEntityTag.strong(expectedETag), forHTTPHeaderField: "If-Match")
        }
        
        print("📤 WebDAV: Sending DELETE request...")
        
        // Destructive mutations do NOT use WebDAVRetryPolicy.perform; a dropped response
        // must not cause a second blind deletion against a recreated resource.
        let data: Data
        let response: URLResponse
        do { (data, response) = try await boundedResponse(for: request) }
        catch {
            if expectedETag == nil { throw StorageError.indeterminateMutation("DELETE response unavailable: " + error.localizedDescription) }
            throw error
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("❌ WebDAV: Invalid response")
            if expectedETag == nil { throw StorageError.indeterminateMutation("DELETE returned no HTTP response") }
            throw WebDAVError.invalidResponse
        }
        
        print("📥 WebDAV: Received response")
        print("   Status code: \(httpResponse.statusCode)")
        
        if httpResponse.statusCode == 404 {
            print("ℹ️ WebDAV: Resource does not exist on server (404), treated as deleted")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            return
        }
        
        if httpResponse.statusCode == 412 {
            throw StorageError.serverError(statusCode: 412, message: "Precondition Failed: remote resource version does not match delete baseline")
        }
        
        do { try WebDAVMutationResponseValidator.validate(statusCode: httpResponse.statusCode, data: data) }
        catch {
            if expectedETag == nil { throw StorageError.indeterminateMutation("Collection DELETE may have partially completed: " + error.localizedDescription) }
            throw error
        }
        if expectedETag == nil, httpResponse.statusCode >= 500 {
            throw StorageError.indeterminateMutation("DELETE returned HTTP \(httpResponse.statusCode); its remote effect is unknown")
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            print("❌ WebDAV: Delete failed - HTTP \(httpResponse.statusCode)")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            throw WebDAVError.serverError(httpResponse.statusCode)
        }
        
        print("✅ WebDAV: Delete succeeded")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    }
    
    /// Move/rename (MOVE)
}
