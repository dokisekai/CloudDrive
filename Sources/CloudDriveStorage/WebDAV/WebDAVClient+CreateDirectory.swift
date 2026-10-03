import Foundation
import CloudDriveContracts
import CloudDriveSupport

extension WebDAVClient {
    public func createDirectory(path: String) async throws {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📁 WebDAV.createDirectory: Starting directory creation")
        print("   Original path: \(path)")
        print("   Timestamp: \(Date())")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        guard let baseURL = baseURL else {
            print("❌ WebDAV: Client not configured, cannot create directory")
            throw WebDAVError.notConfigured
        }
        
        print("✅ WebDAV: Client configured")
        print("   Base URL: \(baseURL.absoluteString)")
        
        // 确保路径格式正确，避免双斜杠问题
        var cleanPath = path
        if cleanPath.hasPrefix("/") {
            cleanPath = String(cleanPath.dropFirst())
        }
        
        print("🧹 WebDAV: Path cleaning")
        print("   Original path: \(path)")
        print("   Cleaned path: \(cleanPath)")
        
        // 递归创建父目录
        let pathComponents = cleanPath.split(separator: "/").map(String.init)
        print("📂 WebDAV: Path components analysis")
        print("   Component count: \(pathComponents.count)")
        for (index, component) in pathComponents.enumerated() {
            print("   [\(index)]: \(component)")
        }
        
        var currentPath = ""
        
        for (index, component) in pathComponents.enumerated() {
            if !currentPath.isEmpty {
                currentPath += "/"
            }
            currentPath += component
            
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("📁 WebDAV: Processing path component [\(index)/\(pathComponents.count-1)]")
            print("   Component: \(component)")
            print("   Current path: \(currentPath)")
            
            // 检查目录是否已存在
            let checkURL = try buildURL(for: currentPath)
            print("🔍 WebDAV: Checking if directory exists")
            print("   Check URL: \(checkURL.absoluteString)")
            
            var checkRequest = URLRequest(url: checkURL)
            checkRequest.httpMethod = "PROPFIND"
            checkRequest.setValue("0", forHTTPHeaderField: "Depth")
            checkRequest.timeoutInterval = 15
            
            // 添加认证
            if let credentials = credentials {
                let authString = "\(credentials.user!):\(credentials.password!)"
                if let authData = authString.data(using: .utf8) {
                    let base64Auth = authData.base64EncodedString()
                    checkRequest.setValue("Basic \(base64Auth)", forHTTPHeaderField: "Authorization")
                    print("🔑 WebDAV: Authorization added")
                }
            }
            
            do {
                print("📤 WebDAV: Sending PROPFIND check request...")
                let (_, checkResponse) = try await WebDAVRetryPolicy.perform { try await session.data(for: checkRequest) }
                if let httpResponse = checkResponse as? HTTPURLResponse {
                    print("📥 WebDAV: Check response status: \(httpResponse.statusCode)")
                    if (200...299).contains(httpResponse.statusCode) {
                        print("✅ WebDAV: Directory exists, skipping creation: \(currentPath)")
                        continue // 目录已存在，跳过创建
                    } else {
                        print("ℹ️ WebDAV: Directory does not exist (status: \(httpResponse.statusCode)), will create")
                    }
                } else {
                    print("⚠️ WebDAV: Check response invalid, attempting directory creation")
                }
            } catch {
                print("⚠️ WebDAV: Directory check failed: \(error), attempting directory creation")
            }
            
            // 创建目录
            let url = try buildURL(for: currentPath)
            var request = URLRequest(url: url)
            request.httpMethod = "MKCOL"
            request.timeoutInterval = 30
            
            print("📁 WebDAV: Creating directory")
            print("   Directory path: \(currentPath)")
            print("   Request URL: \(url.absoluteString)")
            print("   HTTP Method: MKCOL")
            
            // 添加认证
            if let credentials = credentials {
                let authString = "\(credentials.user!):\(credentials.password!)"
                if let authData = authString.data(using: .utf8) {
                    let base64Auth = authData.base64EncodedString()
                    request.setValue("Basic \(base64Auth)", forHTTPHeaderField: "Authorization")
                }
            }
            
            do {
                let (_, response) = try await WebDAVRetryPolicy.perform { try await session.data(for: request) }
                if let httpResponse = response as? HTTPURLResponse {
                    print("📥 WebDAV: Create response status: \(httpResponse.statusCode)")
                    if !(200...299).contains(httpResponse.statusCode) && httpResponse.statusCode != 405 {
                        throw WebDAVError.serverError(httpResponse.statusCode)
                    }
                }
            } catch {
                print("❌ WebDAV: Create directory failed: \(error)")
                throw error
            }
        }
        
        print("✅ WebDAV.createDirectory: Full path creation completed")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    }
    
    /// 删除文件或目录（DELETE）
}
