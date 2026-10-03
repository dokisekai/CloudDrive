import Foundation
import CloudDriveContracts
import CloudDriveSupport
import NetFS
import UniformTypeIdentifiers
import CryptoKit

extension SMBStorageClient {
    // MARK: - StorageClient Implementation
    
    public func exists(path: String) async throws -> Bool {
        do {
            let url = try resolveMountURL(for: path)
            return fileManager.fileExists(atPath: url.path)
        } catch {
            return false
        }
    }
    
    public func listDirectory(path: String) async throws -> [StorageResource] {
        let url = try resolveMountURL(for: path)
        guard fileManager.fileExists(atPath: url.path) else {
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
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = cleanPath.isEmpty ? "" : "/\(cleanPath)"
        
        for item in contents {
            let values = try item.resourceValues(forKeys: [
                .nameKey,
                .isDirectoryKey,
                .fileSizeKey,
                .contentTypeKey,
                .creationDateKey,
                .contentModificationDateKey
            ])
            let isDir = values.isDirectory ?? false
            let name = values.name ?? item.lastPathComponent
            let itemVFSPath = "\(prefix)/\(name)"
            let size = isDir ? 0 : Int64(values.fileSize ?? 0)
            let etag = isDir ? nil : makeETag(for: item)
            
            resources.append(StorageResource(
                path: itemVFSPath,
                displayName: name,
                isDirectory: isDir,
                contentLength: size,
                contentType: values.contentType?.identifier,
                creationDate: values.creationDate,
                lastModified: values.contentModificationDate,
                etag: etag
            ))
        }
        return resources
    }
}
