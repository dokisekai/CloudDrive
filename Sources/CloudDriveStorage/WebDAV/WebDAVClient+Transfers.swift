import Foundation
import CloudDriveContracts
import CloudDriveSupport

extension WebDAVClient {
    public func downloadFile(path: String, to destinationURL: URL, progress: @escaping (Double) -> Void) async throws {
        _ = try await downloadFile(path: path, to: destinationURL, expectedETag: nil, progress: progress)
    }

    @discardableResult
    public func downloadFile(path: String, to destinationURL: URL, expectedETag: String?, progress: @escaping (Double) -> Void) async throws -> String? {
        try await downloadFile(path: path, to: destinationURL, expectedETag: expectedETag, maximumBytes: nil, progress: progress)
    }

    public func downloadFile(path: String, to destinationURL: URL, expectedETag: String?, maximumBytes: Int64?, progress: @escaping (Double) -> Void) async throws -> String? {
        var request = URLRequest(url: try buildURL(for: path))
        request.httpMethod = "GET"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        addAuthentication(to: &request)
        if let expectedETag = expectedETag {
            request.setValue(try WebDAVEntityTag.strong(expectedETag), forHTTPHeaderField: "If-Match")
        }
        let delegate = WebDAVTransferDelegate(progress: progress, maximumBytes: maximumBytes)
        let (temporaryURL, response): (URL, URLResponse)
        do {
            (temporaryURL, response) = try await WebDAVRetryPolicy.perform { try await session.download(for: request, delegate: delegate) }
        } catch let error as URLError where maximumBytes != nil && error.code == .cancelled && !Task.isCancelled {
            throw StorageError.notSupported("Verification download exceeded its expected payload size")
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse }
        guard http.statusCode == 200 else { throw WebDAVError.serverError(http.statusCode) }
        if let encoding = http.value(forHTTPHeaderField: "Content-Encoding"), encoding.lowercased() != "identity" { throw WebDAVError.invalidResponse }
        if let expectedETag, http.value(forHTTPHeaderField: "ETag") != expectedETag {
            throw WebDAVError.invalidResponse
        }
        if let maximumBytes {
            let size = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
            guard size >= 0, Int64(size) <= maximumBytes else { throw StorageError.notSupported("Verification download exceeded its expected payload size") }
        }
        try Task.checkCancellation()
        let manager = FileManager.default
        let parent = destinationURL.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staged = parent.appendingPathComponent(".clouddrive-download-" + UUID().uuidString)
        defer { try? manager.removeItem(at: staged) }
        // 优先零拷贝原子移动，跨宗卷或特定权限受限时安全降级为 copyItem
        do {
            try manager.moveItem(at: temporaryURL, to: staged)
        } catch {
            try manager.copyItem(at: temporaryURL, to: staged)
        }
        if manager.fileExists(atPath: destinationURL.path) {
            _ = try manager.replaceItemAt(destinationURL, withItemAt: staged)
        } else {
            try manager.moveItem(at: staged, to: destinationURL)
        }
        progress(1.0)
        return http.value(forHTTPHeaderField: "ETag")
    }

    /// 下载指定字节范围 (HTTP Range: bytes=start-end)
    public func downloadRange(path: String, range: ClosedRange<Int64>) async throws -> Data {
        try await downloadRange(path: path, range: range, expectedETag: nil)
    }

    public func downloadRange(path: String, range: ClosedRange<Int64>, expectedETag: String?) async throws -> Data {
        guard range.lowerBound >= 0, range.upperBound < Int64.max,
              range.upperBound - range.lowerBound < 32 * 1024 * 1024 else {
            throw WebDAVError.invalidPath
        }
        let requestedLength = range.upperBound - range.lowerBound + 1
        var request = URLRequest(url: try buildURL(for: path))
        request.httpMethod = "GET"
        addAuthentication(to: &request)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let expectedETag { request.setValue(try WebDAVEntityTag.strong(expectedETag), forHTTPHeaderField: "If-Match") }
        // Stream to disk: a server ignoring Range must not load a huge file into RAM.
        let (temporaryURL, response): (URL, URLResponse)
        do {
            (temporaryURL, response) = try await WebDAVRetryPolicy.perform {
                try await session.download(for: request, delegate: WebDAVTransferDelegate(maximumBytes: requestedLength))
            }
        } catch let error as URLError where error.code == .cancelled && !Task.isCancelled {
            throw StorageError.notSupported("WebDAV response exceeded the requested byte range")
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse }
        guard http.statusCode == 206 else {
            if http.statusCode == 200 { throw StorageError.notSupported("WebDAV server ignored Range") }
            throw WebDAVError.serverError(http.statusCode)
        }
        if let encoding = http.value(forHTTPHeaderField: "Content-Encoding"), encoding.lowercased() != "identity" { throw WebDAVError.invalidResponse }
        if let expectedETag, http.value(forHTTPHeaderField: "ETag") != expectedETag { throw WebDAVError.invalidResponse }
        guard let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
              contentRange.hasPrefix("bytes ") else { throw WebDAVError.invalidResponse }
        let parts = contentRange.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw WebDAVError.invalidResponse }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start == range.lowerBound, end >= start, end <= range.upperBound,
              parts[1] == "*" || (Int64(parts[1]).map { $0 > end } ?? false) else { throw WebDAVError.invalidResponse }
        let requiredEnd = Int64(parts[1]).map { min(range.upperBound, $0 - 1) } ?? range.upperBound
        guard end == requiredEnd else { throw WebDAVError.invalidResponse }
        let size = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        guard size == end - start + 1, size <= requestedLength else { throw WebDAVError.invalidResponse }
        try Task.checkCancellation()
        return try Data(contentsOf: temporaryURL)
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
            request.setValue(try WebDAVEntityTag.strong(expectedETag), forHTTPHeaderField: "If-Match")
        case .forceOverwrite:
            break
        }
        // An ambiguous network failure is not replayed: PUT may already have committed.
        // Retrying with the old ETag would falsely label a successful commit as a conflict.
        do {
            let http = try await uploadCoordinator.upload(session: uploadSession, request: request, source: localURL, progress: progress)
            try Task.checkCancellation()
            guard [200, 201, 204].contains(http.statusCode) else {
                if http.statusCode == 412 { throw StorageError.serverError(statusCode: 412, message: "Precondition Failed") }
                throw WebDAVError.serverError(http.statusCode)
            }
            progress(1.0)
            return http.value(forHTTPHeaderField: "ETag")
        } catch {
            // A lost reply or a stale-validator replay can represent our prior
            // commit. Only all-byte comparison of a revision-bound GET proves it.
            if StorageContentVerification.mayHaveCommitted(error),
               let verified = try? await verifiedUploadRevision(localURL: localURL, remotePath: remotePath) {
                try Task.checkCancellation()
                progress(1.0)
                return verified
            }
            try Task.checkCancellation()
            throw error
        }
    }

    private func verifiedUploadRevision(localURL: URL, remotePath: String) async throws -> String? {
        let storage = WebDAVStorageClient(webDAVClient: self)
        guard let resource = try await storage.currentResource(path: remotePath), !resource.isDirectory,
              let etag = resource.etag else { return nil }
        _ = try WebDAVEntityTag.strong(etag)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("dav-verify-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let size = try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        guard size >= 0, resource.contentLength == Int64(size) else { return nil }
        let delivered = try await downloadFile(path: remotePath, to: temporary, expectedETag: etag, maximumBytes: Int64(size)) { _ in }
        guard delivered == etag, try StorageContentVerification.identical(localURL, temporary) else { return nil }
        try Task.checkCancellation()
        return etag
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
