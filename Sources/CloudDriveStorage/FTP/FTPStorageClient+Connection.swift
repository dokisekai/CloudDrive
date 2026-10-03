import Foundation
import CloudDriveContracts
import CloudDriveSupport
import Network
import UniformTypeIdentifiers

extension FTPStorageClient {
    public func testConnection() async throws -> Bool {
        do {
            try await executeFTPCommand { conn in
                let pwd = try await conn.sendCommand("PWD")
                guard pwd.code == 257 || pwd.code == 200 else {
                    throw StorageError.invalidOperation
                }
            }
            return true
        } catch {
            return false
        }
    }
}
