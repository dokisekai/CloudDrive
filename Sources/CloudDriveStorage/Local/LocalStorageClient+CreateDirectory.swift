import Foundation
import CloudDriveContracts
import CloudDriveSupport
import UniformTypeIdentifiers

extension LocalStorageClient {
    public func createDirectory(path: String) async throws {
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
        
        if fileManager.fileExists(atPath: path) {
            var isDir: ObjCBool = false
            fileManager.fileExists(atPath: path, isDirectory: &isDir)
            if isDir.boolValue { return }
            throw StorageError.invalidOperation
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
