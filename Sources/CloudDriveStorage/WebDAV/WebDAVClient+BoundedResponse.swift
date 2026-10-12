import Foundation
import CloudDriveContracts

extension WebDAVClient {
    /// Stage XML on disk and stop oversized responses before allocating a body.
    func boundedResponse(for request: URLRequest, maximumBytes: Int64 = 64 * 1024 * 1024) async throws -> (Data, URLResponse) {
        let delegate = WebDAVTransferDelegate(maximumBytes: maximumBytes)
        let (temporaryURL, response): (URL, URLResponse)
        do { (temporaryURL, response) = try await session.download(for: request, delegate: delegate) }
        catch let error as URLError where error.code == .cancelled && !Task.isCancelled {
            throw StorageError.notSupported("WebDAV response exceeded the configured XML size limit")
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let size = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        guard size >= 0, Int64(size) <= maximumBytes else {
            throw StorageError.notSupported("WebDAV response exceeded the configured XML size limit")
        }
        return (try Data(contentsOf: temporaryURL), response)
    }
}
