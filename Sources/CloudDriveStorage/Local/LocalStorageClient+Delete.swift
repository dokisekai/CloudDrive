import Foundation
import CloudDriveContracts
import CloudDriveSupport
import UniformTypeIdentifiers

extension LocalStorageClient {
    public func delete(path: String) async throws {
        try await delete(path: path, expectedETag: nil)
    }

    public func delete(path: String, expectedETag: String?) async throws {
        let url = URL(fileURLWithPath: path)
        var hasAccess = false
        if let securityURL = securityScopedURL, isAccessingSecurityScope {
            if url.path.hasPrefix(securityURL.path) {
                // 范围已覆盖
            } else {
                hasAccess = url.startAccessingSecurityScopedResource()
            }
        } else {
            hasAccess = url.startAccessingSecurityScopedResource()
        }
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        
        guard fileManager.fileExists(atPath: path) else { return }

        if let expectedETag = expectedETag {
            if let current = currentETag(atPath: path), current != expectedETag {
                throw StorageError.serverError(statusCode: 412, message: "Precondition Failed: remote resource changed since last read")
            }
        }

        try fileManager.removeItem(at: url)
    }
}
