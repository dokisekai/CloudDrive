import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit
import UniformTypeIdentifiers

extension Pan123StorageClient {
    public func downloadFile(path: String, to destinationURL: URL, progress: @escaping (Double) -> Void) async throws {
        try await downloadFile(path: path, to: destinationURL, expectedETag: nil, progress: progress)
    }
    
    /// 下载文件（带版本约束）
    @discardableResult
    public func downloadFile(
        path: String,
        to destinationURL: URL,
        expectedETag: String?,
        progress: @escaping (Double) -> Void
    ) async throws -> String? {
        let canonical = normalizePath(path)
        let fileNode = try await resolveNode(for: canonical)
        guard !fileNode.isDirectory else {
            throw StorageError.invalidOperation
        }
        
        if let expected = expectedETag, let remoteETag = fileNode.etag, !remoteETag.isEmpty, remoteETag != expected {
            throw StorageError.serverError(statusCode: 412, message: "Expected ETag \(expected) does not match remote \(remoteETag)")
        }
        
        // 1. 获取下载临时链接
        let downloadData: Pan123DownloadData = try await apiClient.sendRequest(
            path: "api/v1/file/download_info",
            method: "GET",
            queryItems: [URLQueryItem(name: "fileId", value: String(fileNode.fileId))]
        )
        
        guard let downloadURL = URL(string: downloadData.downloadUrl) else {
            throw StorageError.serverError(statusCode: 500, message: "Invalid download URL returned from 123pan")
        }
        
        // 2. 流式下载
        var dlRequest = URLRequest(url: downloadURL)
        dlRequest.httpMethod = "GET"
        let (data, response) = try await session.data(for: dlRequest)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 500
            throw StorageError.serverError(statusCode: code, message: "Download failed from CDN")
        }
        
        let parentDir = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        
        let stagedURL = parentDir.appendingPathComponent(".clouddrive-123dl-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        try data.write(to: stagedURL, options: [.atomic])
        
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: stagedURL)
        } else {
            try FileManager.default.moveItem(at: stagedURL, to: destinationURL)
        }
        
        progress(1.0)
        // 记录今日已用下载流量至 SQLite 数据库
        try? apiClient.databaseStore.recordDownloadBytes(clientID: config.clientID, bytes: Int64(data.count))
        return fileNode.etag
    }
    
    /// 移动 / 重命名
}
