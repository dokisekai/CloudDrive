import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit
import UniformTypeIdentifiers

extension S3StorageClient {
    public func copy(from sourcePath: String, to destinationPath: String) async throws {
        let srcKey = resolveKey(sourcePath)
        let dstKey = resolveKey(destinationPath)
        if srcKey == dstKey { return }
        
        if try await exists(path: destinationPath) {
            throw StorageError.serverError(statusCode: 412, message: "Target already exists")
        }
        
        let (dstURL, dstHost) = try buildURL(key: dstKey)
        var copyReq = URLRequest(url: dstURL)
        copyReq.httpMethod = "PUT"
        let encodedSrc = "/\(config.bucket)/\(srcKey)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "/\(config.bucket)/\(srcKey)"
        copyReq.setValue(encodedSrc, forHTTPHeaderField: "x-amz-copy-source")
        let empty = Data()
        signRequest(&copyReq, host: dstHost, payloadData: empty)
        copyReq.httpBody = empty
        let (data, resp) = try await session.data(for: copyReq)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "S3 copy failed"
            throw StorageError.serverError(statusCode: (resp as? HTTPURLResponse)?.statusCode ?? 500, message: msg)
        }
    }
}
