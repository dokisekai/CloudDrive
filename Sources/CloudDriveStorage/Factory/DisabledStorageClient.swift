import Foundation
import CloudDriveContracts

/// Historical configurations remain readable, but cannot start a disabled backend.
final class DisabledStorageClient: StorageClient {
    private let type: StorageType
    init(type: StorageType) { self.type = type }
    private var error: StorageError { .notSupported("Only WebDAV is enabled (disabled: \(type.rawValue))") }
    func listDirectory(path: String) async throws -> [StorageResource] { throw error }
    func downloadFile(path: String, to destinationURL: URL, progress: @escaping (Double) -> Void) async throws { throw error }
    func uploadFile(localURL: URL, to remotePath: String, progress: @escaping (Double) -> Void) async throws { throw error }
    func createDirectory(path: String) async throws { throw error }
    func delete(path: String) async throws { throw error }
    func move(from sourcePath: String, to destinationPath: String) async throws { throw error }
    func exists(path: String) async throws -> Bool { throw error }
    func testConnection() async throws -> Bool { throw error }
}
