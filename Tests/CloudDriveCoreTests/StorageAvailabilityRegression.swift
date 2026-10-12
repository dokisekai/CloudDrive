import Foundation
import CloudDriveCore
import CloudDriveStorage

func runStorageAvailabilityRegressionTests() async throws {
    guard StorageType.webdav.isAvailable, StorageType.baidupan.isAvailable else {
        throw StorageError.invalidOperation
    }
    let disabled: [StorageConfiguration] = [
        .local(LocalStorageConfig(path: "/tmp")),
        .s3(S3StorageConfig(bucket: "disabled", accessKey: "", secretKey: "")),
        .ftp(FTPStorageConfig(host: "127.0.0.1", username: "", password: "")),
        .smb(SMBStorageConfig(host: "127.0.0.1", share: "disabled")),
        .pan123(Pan123StorageConfig())
    ]
    for configuration in disabled {
        guard !configuration.type.isAvailable else { throw StorageError.invalidOperation }
        let client = StorageClientFactory.createClient(configuration: configuration)
        do {
            _ = try await client.listDirectory(path: "/")
            throw StorageError.invalidOperation
        } catch StorageError.notSupported { }
    }
    let legacy = VaultInfo(id: "disabled", name: "legacy", storagePath: "/tmp", createdAt: Date(), storageType: .local)
    guard !legacy.isStorageEnabled else { throw StorageError.invalidOperation }
    let legacyBridge = VaultInfo(id: "bridge", name: "legacy", storagePath: "/tmp", createdAt: Date(), storageType: .local, webdavURL: "http://127.0.0.1:28282/", webdavUsername: "local")
    do {
        _ = try await StorageClientFactory.createClient(for: legacyBridge).listDirectory(path: "/")
        throw StorageError.invalidOperation
    } catch StorageError.notSupported { }
    print("✅ WebDAV-only availability regressions passed")
}
