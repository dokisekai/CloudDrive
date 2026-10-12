import Foundation
import CloudDriveContracts
import CloudDriveSupport

extension WebDAVClient {
    public func createDirectory(path: String) async throws {
        guard baseURL != nil else {
            throw WebDAVError.notConfigured
        }
        
        let targetURL = try buildURL(for: path)
        guard let baseURL else { throw WebDAVError.notConfigured }
        let root = baseURL.path.split(separator: "/")
        let target = targetURL.path.split(separator: "/")
        guard target.starts(with: root) else { throw WebDAVError.invalidPath }
        var url = baseURL
        for component in target.dropFirst(root.count) {
            url.appendPathComponent(String(component))
            var request = URLRequest(url: url)
            request.httpMethod = "MKCOL"
            request.timeoutInterval = 30
            addAuthentication(to: &request)
            
            let (_, response) = try await WebDAVRetryPolicy.perform { try await boundedResponse(for: request) }
            guard let httpResponse = response as? HTTPURLResponse else {
                throw WebDAVError.invalidResponse
            }
            
            // 200...299 (创建成功) 或 405 (已存在) 均视为成功
            if httpResponse.statusCode == 405 {
                guard let existing = try await resource(path: url.path), existing.isDirectory else {
                    throw StorageError.serverError(statusCode: 409, message: "MKCOL target exists as a file or cannot be verified")
                }
            } else if ![200, 201, 204].contains(httpResponse.statusCode) {
                throw WebDAVError.serverError(httpResponse.statusCode)
            }
        }
    }
    
    /// 删除文件或目录（DELETE）
}
