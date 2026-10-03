import Foundation
import CloudDriveContracts
import CloudDriveSupport
import NetFS
import UniformTypeIdentifiers
import CryptoKit

extension SMBStorageClient {
    public func downloadFile(path: String, to destinationURL: URL, progress: @escaping (Double) -> Void) async throws {
        let sourceURL = try resolveMountURL(for: path)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw StorageError.notFound
        }
        
        let parentDir = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        
        let stagingURL = parentDir.appendingPathComponent(".clouddrive_download_" + UUID().uuidString)
        defer { try? fileManager.removeItem(at: stagingURL) }
        
        try fileManager.copyItem(at: sourceURL, to: stagingURL)
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        }
        progress(1.0)
    }
    
    public func uploadFile(localURL: URL, to remotePath: String, progress: @escaping (Double) -> Void) async throws {
        try await uploadFile(localURL: localURL, to: remotePath, mode: .forceOverwrite, progress: progress)
    }
    
    @discardableResult
    public func uploadFile(localURL: URL, to remotePath: String, mode: StorageWriteMode, progress: @escaping (Double) -> Void) async throws -> String? {
        let destinationURL = try resolveMountURL(for: remotePath)
        let parentDir = destinationURL.deletingLastPathComponent()
        
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        
        let exists = fileManager.fileExists(atPath: destinationURL.path)
        let currentETag: String? = exists ? makeETag(for: destinationURL) : nil
        
        switch mode {
        case .createIfAbsent:
            if exists {
                throw StorageError.serverError(statusCode: 412, message: "Target already exists")
            }
        case .replace(let expectedETag):
            guard exists else {
                throw StorageError.notFound
            }
            guard currentETag == expectedETag else {
                throw StorageError.serverError(statusCode: 412, message: "Precondition Failed: expected ETag \(expectedETag), got \(currentETag ?? "none")")
            }
        case .forceOverwrite:
            break
        }
        
        let stagingURL = parentDir.appendingPathComponent(".clouddrive_staging_" + UUID().uuidString)
        defer { try? fileManager.removeItem(at: stagingURL) }
        
        try fileManager.copyItem(at: localURL, to: stagingURL)
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        }
        
        progress(1.0)
        return makeETag(for: destinationURL)
    }
}
