import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit
import UniformTypeIdentifiers

extension S3StorageClient {
    public func createDirectory(path: String) async throws {
        let key = resolveKey(path, isDirectory: true)
        if key.isEmpty || key == "/" { return }
        
        let (url, host) = try buildURL(key: key)
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/x-directory", forHTTPHeaderField: "Content-Type")
        let empty = Data()
        signRequest(&req, host: host, payloadData: empty)
        req.httpBody = empty
        
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw StorageError.invalidOperation
        }
    }
}
