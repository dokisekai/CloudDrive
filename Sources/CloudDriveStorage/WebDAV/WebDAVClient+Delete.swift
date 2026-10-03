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
        print("📡 WebDAV: Delete URL: \(url.absoluteString)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30  // 30秒超时
        
        // 添加认证
        if let credentials = credentials {
            let authString = "\(credentials.user!):\(credentials.password!)"
            if let authData = authString.data(using: .utf8) {
                let base64Auth = authData.base64EncodedString()
                request.setValue("Basic \(base64Auth)", forHTTPHeaderField: "Authorization")
                print("🔑 WebDAV: Authorization added (User: \(credentials.user!))")
            }
        } else {
            print("⚠️ WebDAV: No credentials configured")
        }

        if let expectedETag = expectedETag {
            guard !expectedETag.hasPrefix("W/") else {
                throw StorageError.notSupported("A weak ETag cannot protect a delete operation")
            }
            request.setValue(expectedETag, forHTTPHeaderField: "If-Match")
        }
        
        print("📤 WebDAV: Sending DELETE request...")
        
        // Destructive mutations do NOT use WebDAVRetryPolicy.perform; a dropped response
        // must not cause a second blind deletion against a recreated resource.
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("❌ WebDAV: Invalid response")
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
        
        try WebDAVMutationResponseValidator.validate(statusCode: httpResponse.statusCode, data: data)
        
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
