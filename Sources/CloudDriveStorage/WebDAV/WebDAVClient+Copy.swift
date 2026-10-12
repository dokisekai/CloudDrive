import Foundation
import CloudDriveContracts
import CloudDriveSupport

extension WebDAVClient {
    public func copy(from sourcePath: String, to destinationPath: String, overwrite: Bool = false) async throws {
        _ = try await copy(from: sourcePath, to: destinationPath, expectedETag: nil, overwrite: overwrite)
    }

    /// Copy file or directory on remote storage (COPY，支持版本约束)
    public func copy(from sourcePath: String, to destinationPath: String, expectedETag: String?, overwrite: Bool = false) async throws -> String? {
        guard baseURL != nil else {
            throw WebDAVError.notConfigured
        }
        
        let sourceURL = try buildURL(for: sourcePath)
        let destinationURL = try buildURL(for: destinationPath)
        
        var request = URLRequest(url: sourceURL)
        request.httpMethod = "COPY"
        request.setValue(destinationURL.absoluteString, forHTTPHeaderField: "Destination")
        request.setValue(overwrite ? "T" : "F", forHTTPHeaderField: "Overwrite")
        
        // Add authentication
        addAuthentication(to: &request)

        if let expectedETag = expectedETag {
            request.setValue(try WebDAVEntityTag.strong(expectedETag), forHTTPHeaderField: "If-Match")
        }
        
        let (data, response) = try await boundedResponse(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw WebDAVError.serverError(statusCode)
        }

        if httpResponse.statusCode == 412 {
            throw StorageError.serverError(statusCode: 412, message: "Precondition Failed: remote resource version does not match copy baseline")
        }

        try WebDAVMutationResponseValidator.validate(statusCode: httpResponse.statusCode, data: data)

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebDAVError.serverError(httpResponse.statusCode)
        }
        return httpResponse.value(forHTTPHeaderField: "ETag")
    }
    
}
