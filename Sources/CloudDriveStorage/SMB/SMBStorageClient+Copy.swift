import Foundation
import CloudDriveContracts
import CloudDriveSupport
import NetFS
import UniformTypeIdentifiers
import CryptoKit

extension SMBStorageClient {
    public func copy(from sourcePath: String, to destinationPath: String) async throws {
        let sourceURL = try resolveMountURL(for: sourcePath)
        let destinationURL = try resolveMountURL(for: destinationPath)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw StorageError.notFound
        }
        let parentDir = destinationURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        if fileManager.fileExists(atPath: destinationURL.path) {
            throw StorageError.serverError(statusCode: 412, message: "Target already exists")
        }
        let stagingURL = parentDir.appendingPathComponent(".clouddrive_staging_" + UUID().uuidString)
        defer { try? fileManager.removeItem(at: stagingURL) }
        try fileManager.copyItem(at: sourceURL, to: stagingURL)
        try fileManager.moveItem(at: stagingURL, to: destinationURL)
    }
}
