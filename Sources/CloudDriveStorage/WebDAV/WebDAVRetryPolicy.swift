import Foundation
import CloudDriveContracts
import CloudDriveSupport

enum WebDAVRetryPolicy {
    static func perform<T>(
        operation: () async throws -> (T, URLResponse)
    ) async throws -> (T, URLResponse) {
        let maxRetries = 3
        var retries = 0
        var backoff: UInt64 = 1_000_000_000 // 1秒
        
        while true {
            let result: (T, URLResponse)
            do {
                result = try await operation()
            } catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled || retries >= maxRetries { throw error }
                print("⚠️ WebDAV: Network request failed (URLError: \(error.code.rawValue)), retrying \(retries + 1)/\(maxRetries)...")
                try await Task.sleep(nanoseconds: backoff)
                retries += 1
                backoff *= 2
                continue
            }
            
            if let httpResponse = result.1 as? HTTPURLResponse {
                let statusCode = httpResponse.statusCode
                if [429, 500, 502, 503, 504].contains(statusCode) && retries < maxRetries {
                    print("⚠️ WebDAV: Server returned status \(statusCode), retrying \(retries + 1)/\(maxRetries)...")
                    try await Task.sleep(nanoseconds: backoff)
                    retries += 1
                    backoff *= 2
                    continue
                }
            }
            
            return result
        }
    }
    
}
