import Foundation
import CloudDriveContracts
import CloudDriveSupport
import Network
import UniformTypeIdentifiers

extension FTPStorageClient {
    public func downloadFile(path: String, to destinationURL: URL, progress: @escaping (Double) -> Void) async throws {
        guard let url = buildFTPURL(for: path) else {
            throw StorageError.invalidOperation
        }
        
        let (tempURL, _) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        let parentDir = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        
        let stagingURL = parentDir.appendingPathComponent(".clouddrive_download_" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        
        try FileManager.default.copyItem(at: tempURL, to: stagingURL)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: stagingURL)
        } else {
            try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
        }
        progress(1.0)
    }
    
    public func uploadFile(localURL: URL, to remotePath: String, progress: @escaping (Double) -> Void) async throws {
        try await uploadFile(localURL: localURL, to: remotePath, mode: .forceOverwrite, progress: progress)
    }
    
    @discardableResult
    public func uploadFile(localURL: URL, to remotePath: String, mode: StorageWriteMode, progress: @escaping (Double) -> Void) async throws -> String? {
        let isExisting = try await exists(path: remotePath)
        switch mode {
        case .createIfAbsent:
            if isExisting {
                throw StorageError.serverError(statusCode: 412, message: "Target already exists")
            }
        case .replace:
            guard isExisting else {
                throw StorageError.notFound
            }
        case .forceOverwrite:
            break
        }
        
        guard let url = buildFTPURL(for: remotePath) else {
            throw StorageError.invalidOperation
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        
        let (_, resp) = try await session.upload(for: request, fromFile: localURL)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw StorageError.serverError(statusCode: http.statusCode, message: "FTP 上传失败")
        }
        progress(1.0)
        return nil
    }
}
