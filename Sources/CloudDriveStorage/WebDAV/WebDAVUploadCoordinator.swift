import Foundation
import CloudDriveContracts

/// Uploads file bytes without retaining the server's response body in memory.
/// One coordinator serves a persistent session, preserving connection reuse.
final class WebDAVUploadCoordinator: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let responseLimit: Int64 = 1024 * 1024
    private let lock = NSLock()
    private var states: [Int: State] = [:]

    private final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func bind(_ task: URLSessionTask) {
            let cancel = lock.withLock { self.task = task; return cancelled }
            if cancel { task.cancel() }
        }
        func cancel() {
            let task = lock.withLock { cancelled = true; return self.task }
            task?.cancel()
        }
    }

    private final class State {
        let continuation: CheckedContinuation<HTTPURLResponse, Error>
        let progress: (Double) -> Void
        let handle: Handle
        var responseBytes: Int64 = 0
        var failure: Error?
        init(continuation: CheckedContinuation<HTTPURLResponse, Error>, progress: @escaping (Double) -> Void, handle: Handle) {
            self.continuation = continuation
            self.progress = progress
            self.handle = handle
        }
    }

    func upload(session: URLSession, request: URLRequest, source: URL, progress: @escaping (Double) -> Void) async throws -> HTTPURLResponse {
        let handle = Handle()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = session.uploadTask(with: request, fromFile: source)
                lock.withLock { states[task.taskIdentifier] = State(continuation: continuation, progress: progress, handle: handle) }
                handle.bind(task)
                task.resume()
            }
        }, onCancel: { handle.cancel() })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let excessive = response.expectedContentLength > Self.responseLimit
        if excessive {
            lock.withLock {
                states[dataTask.taskIdentifier]?.failure = StorageError.serverError(statusCode: 502, message: "WebDAV PUT response exceeded its size limit")
            }
        }
        completionHandler(excessive ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let excessive = lock.withLock {
            guard let state = states[dataTask.taskIdentifier] else { return false }
            // Check before adding to avoid integer overflow on hostile streams.
            if Int64(data.count) > Self.responseLimit - state.responseBytes {
                state.failure = StorageError.serverError(statusCode: 502, message: "WebDAV PUT response exceeded its size limit")
                return true
            }
            state.responseBytes += Int64(data.count)
            return false
        }
        // Response bytes are discarded, including bodies with no Content-Length.
        if excessive { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let progress = lock.withLock { states[task.taskIdentifier]?.progress }
        progress?(min(1, max(0, Double(totalBytesSent) / Double(totalBytesExpectedToSend))))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let state = lock.withLock({ states.removeValue(forKey: task.taskIdentifier) }) else { return }
        if state.handle.isCancelled { state.continuation.resume(throwing: CancellationError()) }
        else if let failure = state.failure { state.continuation.resume(throwing: failure) }
        else if let error { state.continuation.resume(throwing: error) }
        else if let response = task.response as? HTTPURLResponse { state.continuation.resume(returning: response) }
        else { state.continuation.resume(throwing: WebDAVError.invalidResponse) }
    }
}
