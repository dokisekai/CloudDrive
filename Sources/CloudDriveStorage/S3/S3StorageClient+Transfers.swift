import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit
import UniformTypeIdentifiers

extension S3StorageClient {
    public func downloadFile(path: String, to destinationURL: URL, progress: @escaping (Double) -> Void) async throws {
        let key = resolveKey(path)
        let (url, host) = try buildURL(key: key)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        signRequest(&req, host: host)
        
        let delegate = AsyncDownloadProgressDelegate(onProgress: progress)
        let (tempURL, resp) = try await session.download(for: req, delegate: delegate)
        guard let http = resp as? HTTPURLResponse else {
            throw StorageError.networkError("Invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            let data = (try? Data(contentsOf: tempURL)) ?? Data()
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw StorageError.serverError(statusCode: http.statusCode, message: msg)
        }
        
        let parentDir = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let stagingURL = parentDir.appendingPathComponent(".clouddrive_staging_" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        try FileManager.default.moveItem(at: tempURL, to: stagingURL)
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
        let key = resolveKey(remotePath)
        
        switch mode {
        case .createIfAbsent:
            if try await exists(path: remotePath) {
                throw StorageError.serverError(statusCode: 412, message: "Target already exists")
            }
        case .replace(let expectedETag):
            let (url, host) = try buildURL(key: key)
            var headReq = URLRequest(url: url)
            headReq.httpMethod = "HEAD"
            signRequest(&headReq, host: host)
            let (_, headResp) = try await session.data(for: headReq)
            guard let http = headResp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw StorageError.notFound
            }
            let remoteETag = http.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard remoteETag == expectedETag else {
                throw StorageError.serverError(statusCode: 412, message: "Precondition Failed: expected ETag \(expectedETag), got \(remoteETag ?? "none")")
            }
        case .forceOverwrite:
            break
        }
        
        let payloadHash = try computeSHA256(of: localURL)
        let (url, host) = try buildURL(key: key)
        
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        
        let ext = localURL.pathExtension
        let contentType = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        
        signRequest(&req, host: host, payloadHash: payloadHash)
        
        let delegate = AsyncUploadProgressDelegate(onProgress: progress)
        let (data, resp) = try await session.upload(for: req, fromFile: localURL, delegate: delegate)
        guard let http = resp as? HTTPURLResponse else {
            throw StorageError.networkError("Invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw StorageError.serverError(statusCode: http.statusCode, message: msg)
        }
        progress(1.0)
        return http.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
    
    func computeSHA256(of localURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 64 * 1024
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
