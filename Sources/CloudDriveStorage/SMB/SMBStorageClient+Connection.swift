import Foundation
import CloudDriveContracts
import CloudDriveSupport
import NetFS
import UniformTypeIdentifiers
import CryptoKit

extension SMBStorageClient {
    public func testConnection() async throws -> Bool {
        do {
            _ = try ensureMounted()
            return true
        } catch {
            return false
        }
    }
}
