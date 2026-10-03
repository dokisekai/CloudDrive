import Foundation
import CloudDriveContracts
import CloudDriveSupport

extension WebDAVClient {
    public func downloadFile(path: String, to destinationURL: URL, progress: @escaping (Double) -> Void) async throws {
        _ = try await downloadFile(path: path, to: destinationURL, expectedETag: nil, progress: progress)
    }

    @discardableResult
    public func downloadFile(path: String, to destinationURL: URL, expectedETag: String?, progress: @escaping (Double) -> Void) async throws -> String? {
        var request = URLRequest(url: try buildURL(for: path))
        request.httpMethod = "GET"
        addAuthentication(to: &request)
        if let expectedETag = expectedETag {
            request.setValue(expectedETag, forHTTPHeaderField: "If-Match")
        }
        let delegate = AsyncDownloadProgressDelegate(onProgress: progress)
        let (temporaryURL, response) = try await WebDAVRetryPolicy.perform {
            try await session.download(for: request, delegate: delegate)
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw WebDAVError.serverError(http.statusCode) }
        try Task.checkCancellation()
        let manager = FileManager.default
        let parent = destinationURL.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staged = parent.appendingPathComponent(".clouddrive-download-" + UUID().uuidString)
        defer { try? manager.removeItem(at: staged) }
        try manager.copyItem(at: temporaryURL, to: staged)
        if manager.fileExists(atPath: destinationURL.path) {
            _ = try manager.replaceItemAt(destinationURL, withItemAt: staged)
        } else {
            try manager.moveItem(at: staged, to: destinationURL)
        }
        progress(1.0)
        return http.value(forHTTPHeaderField: "ETag")
    }

    public func uploadFile(localURL: URL, to remotePath: String, progress: @escaping (Double) -> Void) async throws {
        _ = try await uploadFile(localURL: localURL, to: remotePath, expectedETag: nil, progress: progress)
    }

    /// If-Match / If-None-Match conditional upload
    @discardableResult
    public func uploadFile(localURL: URL, to remotePath: String, mode: StorageWriteMode, progress: @escaping (Double) -> Void) async throws -> String? {
        guard FileManager.default.fileExists(atPath: localURL.path) else { throw WebDAVError.fileNotFound }
        var request = URLRequest(url: try buildURL(for: remotePath))
        request.httpMethod = "PUT"
        addAuthentication(to: &request)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        switch mode {
        case .createIfAbsent:
            request.setValue("*", forHTTPHeaderField: "If-None-Match")
        case .replace(let expectedETag):
            guard !expectedETag.hasPrefix("W/") else {
                throw StorageError.notSupported("A weak ETag cannot protect an overwrite")
            }
            request.setValue(expectedETag, forHTTPHeaderField: "If-Match")
        case .forceOverwrite:
            break
        }
        let delegate = AsyncUploadProgressDelegate(onProgress: progress)
        // An ambiguous network failure is not replayed: PUT may already have committed.
        // Retrying with the old ETag would falsely label a successful commit as a conflict.
        let (_, response) = try await session.upload(for: request, fromFile: localURL, delegate: delegate)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 412 {
                throw StorageError.serverError(statusCode: 412, message: "Precondition Failed")
            }
            throw WebDAVError.serverError(http.statusCode)
        }
        progress(1.0)
        return http.value(forHTTPHeaderField: "ETag")
    }

    /// If-Match makes the server reject a stale editor without changing remote bytes.
    @discardableResult
    public func uploadFile(localURL: URL, to remotePath: String, expectedETag: String?, progress: @escaping (Double) -> Void) async throws -> String? {
        if let etag = expectedETag {
            return try await uploadFile(localURL: localURL, to: remotePath, mode: .replace(expectedETag: etag), progress: progress)
        } else {
            return try await uploadFile(localURL: localURL, to: remotePath, mode: .forceOverwrite, progress: progress)
        }
    }

}
