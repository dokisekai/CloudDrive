import Foundation
import CloudDriveContracts
import CloudDriveSupport
import UniformTypeIdentifiers

extension LocalStorageClient {
    public func downloadFile(path: String, to destinationURL: URL, progress: @escaping (Double) -> Void) async throws {
        let sourceURL = URL(fileURLWithPath: path)
        var hasAccess = false
        if let securityURL = securityScopedURL, isAccessingSecurityScope {
            if sourceURL.path.hasPrefix(securityURL.path) {
                // 已经在范围内
            } else {
                hasAccess = sourceURL.startAccessingSecurityScopedResource()
            }
        } else {
            hasAccess = sourceURL.startAccessingSecurityScopedResource()
        }
        defer { if hasAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        
        guard fileManager.fileExists(atPath: path) else {
            throw StorageError.notFound
        }
        
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        if copyfile(sourceURL.path, destinationURL.path, nil, copyfile_flags_t(COPYFILE_CLONE)) != 0 {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
        progress(1.0)
    }
    
    public func uploadFile(localURL: URL, to remotePath: String, progress: @escaping (Double) -> Void) async throws {
        _ = try await uploadFile(localURL: localURL, to: remotePath, mode: .forceOverwrite, progress: progress)
    }

    @discardableResult
    public func uploadFile(localURL: URL, to remotePath: String, expectedETag: String?, progress: @escaping (Double) -> Void) async throws -> String? {
        if let etag = expectedETag {
            return try await uploadFile(localURL: localURL, to: remotePath, mode: .replace(expectedETag: etag), progress: progress)
        } else {
            return try await uploadFile(localURL: localURL, to: remotePath, mode: .forceOverwrite, progress: progress)
        }
    }

    @discardableResult
    public func uploadFile(localURL: URL, to remotePath: String, mode: StorageWriteMode, progress: @escaping (Double) -> Void) async throws -> String? {
        let destinationURL = URL(fileURLWithPath: remotePath)
        
        let hasLocalAccess = localURL.startAccessingSecurityScopedResource()
        defer { if hasLocalAccess { localURL.stopAccessingSecurityScopedResource() } }
        
        var hasDestinationAccess = false
        let destinationParent = destinationURL.deletingLastPathComponent()
        if let securityURL = securityScopedURL, isAccessingSecurityScope {
            if destinationURL.path.hasPrefix(securityURL.path) {
                // 已在安全范围
            } else {
                hasDestinationAccess = destinationParent.startAccessingSecurityScopedResource()
            }
        } else {
            hasDestinationAccess = destinationParent.startAccessingSecurityScopedResource()
        }
        defer { if hasDestinationAccess { destinationParent.stopAccessingSecurityScopedResource() } }
        
        if !fileManager.fileExists(atPath: destinationParent.path) {
            try fileManager.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        }
        
        let destinationExists = fileManager.fileExists(atPath: destinationURL.path)

        switch mode {
        case .createIfAbsent:
            if destinationExists {
                throw StorageError.serverError(statusCode: 412, message: "Target already exists")
            }
        case .replace(let expectedETag):
            guard destinationExists else {
                throw StorageError.serverError(statusCode: 412, message: "Target does not exist to replace")
            }
            if let current = currentETag(atPath: destinationURL.path), current != expectedETag {
                throw StorageError.serverError(statusCode: 412, message: "Precondition Failed: remote resource changed since last read")
            }
        case .forceOverwrite:
            break
        }
        
        // Stage to a temporary file in the same directory for crash-safe atomic replacement
        let stagingURL = destinationParent.appendingPathComponent(".clouddrive_staging_\(UUID().uuidString)")
        defer {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        // Prioritize APFS Copy-on-Write (CoW) clone, stream copyItem across volumes
        if copyfile(localURL.path, stagingURL.path, nil, copyfile_flags_t(COPYFILE_CLONE)) != 0 {
            try fileManager.copyItem(at: localURL, to: stagingURL)
        }

        // Atomic commit: never delete destination prior to staging completion
        if destinationExists {
            do {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL, backupItemName: nil, options: [.withoutDeletingBackupItem])
            } catch {
                try fileManager.removeItem(at: destinationURL)
                try fileManager.moveItem(at: stagingURL, to: destinationURL)
            }
        } else {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        }

        progress(1.0)
        return currentETag(atPath: destinationURL.path)
    }
}
