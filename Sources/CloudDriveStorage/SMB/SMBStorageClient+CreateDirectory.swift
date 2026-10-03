import Foundation
import CloudDriveContracts
import CloudDriveSupport
import NetFS
import UniformTypeIdentifiers
import CryptoKit

extension SMBStorageClient {
    public func createDirectory(path: String) async throws {
        let url = try resolveMountURL(for: path)
        if fileManager.fileExists(atPath: url.path) { return }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
