import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit
import UniformTypeIdentifiers

extension S3StorageClient {
    public func testConnection() async throws -> Bool {
        do {
            let query = [
                URLQueryItem(name: "list-type", value: "2"),
                URLQueryItem(name: "max-keys", value: "1")
            ]
            let (url, host) = try buildURL(key: "", queryItems: query)
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            signRequest(&req, host: host)
            let (_, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse {
                return (200...299).contains(http.statusCode)
            }
            return false
        } catch {
            return false
        }
    }
}
