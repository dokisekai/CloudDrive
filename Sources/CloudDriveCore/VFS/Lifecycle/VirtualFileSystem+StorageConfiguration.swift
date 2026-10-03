import Foundation
import CloudDriveStorage

extension VirtualFileSystem {
    public func configureStorage(configuration: StorageConfiguration) {
        print("⚙️ [VFS] Initializing storage client based on configuration: \(configuration.summaryDescription)")
        let client = StorageClientFactory.createClient(configuration: configuration)
        configureStorage(client: client)
        print("✅ [VFS] Storage client configured successfully")
    }

    public func configureWebDAV(baseURL: URL, username: String, password: String) {
        print("⚙️ [VFS] Configuring WebDAV storage")
        print("   URL: \(baseURL)")
        let client = WebDAVStorageClient(config: WebDAVStorageConfig(baseURL: baseURL.absoluteString, username: username, password: password))
        configureStorage(client: client)
        print("✅ [VFS] WebDAV storage configured successfully")
    }
}
