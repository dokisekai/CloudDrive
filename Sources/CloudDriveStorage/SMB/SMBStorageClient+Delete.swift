import Foundation
import CloudDriveContracts
import CloudDriveSupport
import NetFS
import UniformTypeIdentifiers
import CryptoKit

extension SMBStorageClient {
    public func delete(path: String) async throws {
        try await delete(path: path, expectedETag: nil)
    }
    
    public func delete(path: String, expectedETag: String?) async throws {
        let url = try resolveMountURL(for: path)
        guard fileManager.fileExists(atPath: url.path) else { return }
        
        if let expected = expectedETag {
            let actual = makeETag(for: url)
            guard actual == expected else {
                throw StorageError.serverError(statusCode: 412, message: "Precondition Failed: expected ETag \(expected), got \(actual ?? "none")")
            }
        }
        try fileManager.removeItem(at: url)
    }
}
