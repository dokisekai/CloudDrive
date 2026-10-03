import Foundation
import CloudDriveContracts
import CloudDriveSupport

internal final class AsyncUploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: (Double) -> Void
    
    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 {
            let pct = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
            onProgress(min(max(pct, 0.0), 1.0))
        }
    }
}
