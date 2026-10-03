import Foundation
import CloudDriveCore
import CloudDriveStorage

@MainActor
enum StorageConnectionQueries {
    static func testWebDAVConnection(url: String, username: String, password: String) async throws -> Bool {
        print("🔍 AppState: Testing WebDAV connection...")
        
        guard let webdavURL = URL(string: url) else {
            throw NSError(domain: "CloudDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: L("err_invalid_webdav_url")])
        }
        
        // 配置 WebDAV
        let client = WebDAVClient.shared
        client.configure(baseURL: webdavURL, username: username, password: password)
        
        // 测试连接
        let success = try await client.testConnection()
        
        print(success ? "✅ AppState: WebDAV connection test succeeded" : "❌ AppState: WebDAV connection test failed")
        return success
    }

    static func testStorageConnection(configuration: StorageConfiguration) async throws -> Bool {
        print("🔍 AppState: Testing storage connection: \(configuration.summaryDescription)")
        let success = try await StorageClientFactory.testConnection(configuration: configuration)
        print(success ? "✅ AppState: Storage connection test succeeded" : "❌ AppState: Storage connection test failed")
        return success
    }

    static func checkWebDAVVault(
        url: String,
        username: String,
        password: String,
        remotePath: String
    ) async throws -> (connected: Bool, vaultFound: Bool, message: String) {
        guard let webdavURL = URL(string: url) else {
            throw NSError(domain: "CloudDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: L("err_invalid_webdav_url")])
        }
        
        let client = WebDAVClient.shared
        client.configure(baseURL: webdavURL, username: username, password: password)
        
        let connected = try await client.testConnection()
        guard connected else {
            return (false, false, L("err_conn_failed_webdav"))
        }
        
        var cleanPath = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanPath.isEmpty || cleanPath == "/" {
            cleanPath = "/"
        } else {
            if !cleanPath.hasPrefix("/") {
                cleanPath = "/" + cleanPath
            }
            while cleanPath.hasSuffix("/") && cleanPath.count > 1 {
                cleanPath = String(cleanPath.dropLast())
            }
        }
        
        let basePath = cleanPath == "/" ? "" : cleanPath
        let hasMK = (try? await client.exists(path: "\(basePath)/masterkey.cryptomator")) ?? false
        let hasSalt = (try? await client.exists(path: "\(basePath)/salt")) ?? false
        let hasConfig = (try? await client.exists(path: "\(basePath)/vault.cryptomator")) ?? false
        let hasD = (try? await client.exists(path: "\(basePath)/d")) ?? false
        
        if hasMK {
            return (true, true, L("test_conn_success_cryptomator"))
        } else if hasSalt && hasConfig {
            return (true, true, L("test_conn_success_clouddrive"))
        } else if hasD {
            return (true, true, L("test_conn_success_vault_dir"))
        } else {
            return (true, false, L("test_conn_no_config_found", cleanPath))
        }
    }

    static func browseWebDAVDirectory(
        url: String,
        username: String,
        password: String,
        path: String
    ) async throws -> (currentIsVault: Bool, folders: [RemoteFolderItem]) {
        guard let webdavURL = URL(string: url) else {
            throw NSError(domain: "CloudDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: L("err_invalid_webdav_url")])
        }
        
        let client = WebDAVClient.shared
        client.configure(baseURL: webdavURL, username: username, password: password)
        
        return try await client.browseDirectory(path: path)
    }
}
