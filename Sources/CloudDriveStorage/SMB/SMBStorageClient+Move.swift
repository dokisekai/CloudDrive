import Foundation
import CloudDriveContracts
import CloudDriveSupport
import NetFS
import UniformTypeIdentifiers
import CryptoKit

extension SMBStorageClient {
    public func move(from sourcePath: String, to destinationPath: String) async throws {
        try await move(from: sourcePath, to: destinationPath, expectedETag: nil)
    }
    
    public func move(from sourcePath: String, to destinationPath: String, expectedETag: String?) async throws {
        let sourceURL = try resolveMountURL(for: sourcePath)
        let destinationURL = try resolveMountURL(for: destinationPath)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw StorageError.notFound
        }
        
        if let expected = expectedETag {
            let actual = makeETag(for: sourceURL)
            guard actual == expected else {
                throw StorageError.serverError(statusCode: 412, message: "Precondition Failed: expected ETag \(expected), got \(actual ?? "none")")
            }
        }
        
        let parentDir = destinationURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        if fileManager.fileExists(atPath: destinationURL.path) {
            throw StorageError.serverError(statusCode: 412, message: "Target already exists")
        }
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }
}
