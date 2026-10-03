import Foundation
import CloudDriveContracts
import CloudDriveSupport
import UniformTypeIdentifiers

extension LocalStorageClient {
    // MARK: - StorageClient Implementation
    
    public func exists(path: String) async throws -> Bool {
        let url = URL(fileURLWithPath: path)
        if let securityURL = securityScopedURL, isAccessingSecurityScope {
            if url.path.hasPrefix(securityURL.path) {
                return fileManager.fileExists(atPath: path)
            }
        }
        
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        return fileManager.fileExists(atPath: path)
    }
    
    public func listDirectory(path: String) async throws -> [StorageResource] {
        let url = URL(fileURLWithPath: path)
        var hasAccess = false
        if let securityURL = securityScopedURL, isAccessingSecurityScope {
            if url.path.hasPrefix(securityURL.path) {
                // 已经在范围内
            } else {
                hasAccess = url.startAccessingSecurityScopedResource()
            }
        } else {
            hasAccess = url.startAccessingSecurityScopedResource()
        }
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        
        guard fileManager.fileExists(atPath: path, isDirectory: nil) else {
            throw StorageError.notFound
        }
        
        let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [
            .nameKey,
            .isDirectoryKey,
            .fileSizeKey,
            .contentTypeKey,
            .creationDateKey,
            .contentModificationDateKey
        ])
        
        var resources: [StorageResource] = []
        for contentURL in contents {
            let resourceValues = try contentURL.resourceValues(forKeys: [
                .nameKey,
                .isDirectoryKey,
                .fileSizeKey,
                .contentTypeKey,
                .creationDateKey,
                .contentModificationDateKey
            ])
            
            let isDirectory = resourceValues.isDirectory ?? false
            let size = isDirectory ? 0 : (resourceValues.fileSize ?? 0)
            let displayName = resourceValues.name ?? contentURL.lastPathComponent
            
            let etag = isDirectory ? nil : makeETag(size: Int64(size), mtime: resourceValues.contentModificationDate)
            
            let resource = StorageResource(
                path: contentURL.path,
                displayName: displayName,
                isDirectory: isDirectory,
                contentLength: Int64(size),
                contentType: resourceValues.contentType?.identifier,
                creationDate: resourceValues.creationDate,
                lastModified: resourceValues.contentModificationDate,
                etag: etag
            )
            resources.append(resource)
        }
        return resources
    }
}
