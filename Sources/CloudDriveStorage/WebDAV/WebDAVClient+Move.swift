import Foundation
import CloudDriveContracts
import CloudDriveSupport

extension WebDAVClient {
    public func move(from sourcePath: String, to destinationPath: String, overwrite: Bool = false) async throws {
        try await move(from: sourcePath, to: destinationPath, expectedETag: nil, overwrite: overwrite)
    }

    /// Move/rename (MOVE，支持版本约束)
    public func move(from sourcePath: String, to destinationPath: String, expectedETag: String?, overwrite: Bool = false) async throws {
        guard baseURL != nil else {
            throw WebDAVError.notConfigured
        }
        
        let sourceURL = try buildURL(for: sourcePath)
        let destinationURL = try buildURL(for: destinationPath)
        
        var request = URLRequest(url: sourceURL)
        request.httpMethod = "MOVE"
        request.setValue(destinationURL.absoluteString, forHTTPHeaderField: "Destination")
        request.setValue(overwrite ? "T" : "F", forHTTPHeaderField: "Overwrite")
        
        // Add authentication
        if let credentials = credentials {
            let authString = "\(credentials.user!):\(credentials.password!)"
            if let authData = authString.data(using: .utf8) {
                let base64Auth = authData.base64EncodedString()
                request.setValue("Basic \(base64Auth)", forHTTPHeaderField: "Authorization")
            }
        }

        if let expectedETag = expectedETag {
            guard !expectedETag.hasPrefix("W/") else {
                throw StorageError.notSupported("A weak ETag cannot protect a move operation")
            }
            request.setValue(expectedETag, forHTTPHeaderField: "If-Match")
        }
        
        // Destructive mutations do NOT use WebDAVRetryPolicy.perform.
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw WebDAVError.serverError(statusCode)
        }

        if httpResponse.statusCode == 412 {
            throw StorageError.serverError(statusCode: 412, message: "Precondition Failed: remote resource version does not match move baseline")
        }

        try WebDAVMutationResponseValidator.validate(statusCode: httpResponse.statusCode, data: data)

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebDAVError.serverError(httpResponse.statusCode)
        }
    }
    
    /// Copy file or directory on remote storage (COPY)
}
