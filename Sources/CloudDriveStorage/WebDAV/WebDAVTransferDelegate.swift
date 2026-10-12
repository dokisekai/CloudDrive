import Foundation

/// DAV methods and Authorization must not be rewritten or forwarded by redirects.
final class WebDAVTransferDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: (Double) -> Void
    private let maximumBytes: Int64?
    init(progress: @escaping (Double) -> Void = { _ in }, maximumBytes: Int64? = nil) {
        self.progress = progress
        self.maximumBytes = maximumBytes
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Only allow safe, idempotent methods (GET, HEAD, PROPFIND) to follow redirects (301, 302, 303, 307, 308).
        // Destructive mutations (DELETE, MOVE, MKCOL, etc.) must not be blindly redirected.
        guard let originalRequest = task.originalRequest,
              let method = originalRequest.httpMethod?.uppercased(),
              method == "GET" || method == "HEAD" || method == "PROPFIND" else {
            completionHandler(nil)
            return
        }
        
        var redirectedRequest = request
        // If redirecting to a different host (e.g. S3 / OSS / CDN pre-signed storage URL),
        // strip the Authorization header to prevent credential leakage and signature rejection.
        if let originalHost = originalRequest.url?.host?.lowercased(),
           let newHost = request.url?.host?.lowercased(),
           originalHost != newHost {
            redirectedRequest.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(redirectedRequest)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if let maximumBytes, totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes {
            downloadTask.cancel()
            return
        }
        if totalBytesExpectedToWrite > 0 { progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 { progress(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend))) }
    }
}
