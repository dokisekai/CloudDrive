import Foundation
import CloudDriveCore

extension AppState {
    func testWebDAVConnection(url: String, username: String, password: String) async throws -> Bool {
        try await StorageConnectionQueries.testWebDAVConnection(url: url, username: username, password: password)
    }

    func testStorageConnection(configuration: StorageConfiguration) async throws -> Bool {
        try await StorageConnectionQueries.testStorageConnection(configuration: configuration)
    }

    func checkWebDAVVault(url: String, username: String, password: String, remotePath: String) async throws -> (connected: Bool, vaultFound: Bool, message: String) {
        try await StorageConnectionQueries.checkWebDAVVault(url: url, username: username, password: password, remotePath: remotePath)
    }

    func browseWebDAVDirectory(url: String, username: String, password: String, path: String) async throws -> (currentIsVault: Bool, folders: [RemoteFolderItem]) {
        try await StorageConnectionQueries.browseWebDAVDirectory(url: url, username: username, password: password, path: path)
    }
}
