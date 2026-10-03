import Foundation
import CloudDriveContracts
import CloudDriveSupport
import UniformTypeIdentifiers

extension LocalStorageClient {
    public func copy(from sourcePath: String, to destinationPath: String) async throws {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let destinationURL = URL(fileURLWithPath: destinationPath)
        
        var hasSourceAccess = false
        if let securityURL = securityScopedURL, isAccessingSecurityScope {
            if sourceURL.path.hasPrefix(securityURL.path) {
                // Scope covered
            } else {
                hasSourceAccess = sourceURL.startAccessingSecurityScopedResource()
            }
        } else {
            hasSourceAccess = sourceURL.startAccessingSecurityScopedResource()
        }
        defer { if hasSourceAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        
        var hasDestinationAccess = false
        if let securityURL = securityScopedURL, isAccessingSecurityScope {
            if destinationURL.path.hasPrefix(securityURL.path) {
                // Scope covered
            } else {
                hasDestinationAccess = destinationURL.startAccessingSecurityScopedResource()
            }
        } else {
            hasDestinationAccess = destinationURL.startAccessingSecurityScopedResource()
        }
        defer { if hasDestinationAccess { destinationURL.stopAccessingSecurityScopedResource() } }
        
        guard fileManager.fileExists(atPath: sourcePath) else {
            throw StorageError.notFound
        }
        
        if fileManager.fileExists(atPath: destinationPath) {
            throw StorageError.invalidOperation
        }
        
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if copyfile(sourceURL.path, destinationURL.path, nil, copyfile_flags_t(COPYFILE_CLONE)) != 0 {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
    }
}
