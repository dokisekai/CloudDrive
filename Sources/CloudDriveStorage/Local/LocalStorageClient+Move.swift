import Foundation
import CloudDriveContracts
import CloudDriveSupport
import UniformTypeIdentifiers

extension LocalStorageClient {
    public func move(from sourcePath: String, to destinationPath: String) async throws {
        try await move(from: sourcePath, to: destinationPath, expectedETag: nil)
    }

    public func move(from sourcePath: String, to destinationPath: String, expectedETag: String?) async throws {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let destinationURL = URL(fileURLWithPath: destinationPath)
        
        var hasSourceAccess = false
        if let securityURL = securityScopedURL, isAccessingSecurityScope {
            if sourceURL.path.hasPrefix(securityURL.path) {
                // 范围已覆盖
            } else {
                hasSourceAccess = sourceURL.startAccessingSecurityScopedResource()
            }
        } else {
            hasSourceAccess = sourceURL.startAccessingSecurityScopedResource()
        }
        defer { if hasSourceAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        
        var hasDestinationAccess = false
        let destinationParent = destinationURL.deletingLastPathComponent()
        if let securityURL = securityScopedURL, isAccessingSecurityScope {
            if destinationURL.path.hasPrefix(securityURL.path) {
                // 范围已覆盖
            } else {
                hasDestinationAccess = destinationParent.startAccessingSecurityScopedResource()
            }
        } else {
            hasDestinationAccess = destinationParent.startAccessingSecurityScopedResource()
        }
        defer { if hasDestinationAccess { destinationParent.stopAccessingSecurityScopedResource() } }
        
        guard fileManager.fileExists(atPath: sourcePath) else {
            throw StorageError.notFound
        }

        if let expectedETag = expectedETag {
            if let current = currentETag(atPath: sourcePath), current != expectedETag {
                throw StorageError.serverError(statusCode: 412, message: "Precondition Failed: source resource changed since last read")
            }
        }
        
        if fileManager.fileExists(atPath: destinationPath) {
            throw StorageError.invalidOperation
        }
        
        try fileManager.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }
}
