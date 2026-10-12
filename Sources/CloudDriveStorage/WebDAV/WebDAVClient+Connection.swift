import Foundation
import CloudDriveContracts
import CloudDriveSupport

extension WebDAVClient {
    public func testConnection() async throws -> Bool {
        let baseURL = try buildURL(for: "/")
        
        print("🔍 WebDAV: Testing connection...")
        print("📡 WebDAV: Server host: \(baseURL.host ?? "")")
        
        // 使用 PROPFIND 测试根目录访问
        var request = URLRequest(url: baseURL)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10 // 10秒超时
        
        // 添加认证
        addAuthentication(to: &request)
        
        do {
            let (_, response) = try await WebDAVRetryPolicy.perform { try await boundedResponse(for: request) }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("❌ WebDAV: Invalid response")
                throw WebDAVError.invalidResponse
            }
            
            print("📡 WebDAV: Response status code: \(httpResponse.statusCode)")
            
            // 检查状态码
            switch httpResponse.statusCode {
            case 200...299:
                print("✅ WebDAV: Connection successful!")
                return true
            case 401, 403:
                print("❌ WebDAV: Authentication failed (status code: \(httpResponse.statusCode))")
                throw WebDAVError.authenticationFailed
            case 404:
                print("❌ WebDAV: Server address not found (404)")
                throw WebDAVError.serverError(404)
            default:
                print("❌ WebDAV: Server error (status code: \(httpResponse.statusCode))")
                throw WebDAVError.serverError(httpResponse.statusCode)
            }
        } catch let error as WebDAVError {
            throw error
        } catch {
            print("❌ WebDAV: Connection failed: \(error.localizedDescription)")
            throw WebDAVError.serverError(-1)
        }
    }
}
