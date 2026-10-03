import Foundation
import CryptoKit
import CloudDriveCore
import CloudDriveStorage
import CryptomatorCryptoLib

private struct RegressionFailure: Error, CustomStringConvertible {
    let description: String
}

/// Fallback storage client to test default protocol implementations in StorageClient
private final class MockStorageClientWithoutNativeCopy: StorageClient {
    var files: [String: Data] = [:]
    var directories: Set<String> = ["/"]

    func listDirectory(path: String) async throws -> [StorageResource] {
        guard directories.contains(path) else { throw StorageError.notFound }
        var resources: [StorageResource] = []
        for (filePath, data) in files {
            let parent = (filePath as NSString).deletingLastPathComponent
            if parent == path || (path == "/" && parent.isEmpty) {
                resources.append(StorageResource(
                    path: filePath,
                    displayName: (filePath as NSString).lastPathComponent,
                    isDirectory: false,
                    contentLength: Int64(data.count)
                ))
            }
        }
        return resources
    }

    func downloadFile(path: String, to destinationURL: URL, progress: @escaping (Double) -> Void) async throws {
        guard let data = files[path] else { throw StorageError.notFound }
        try data.write(to: destinationURL)
        progress(1.0)
    }

    func uploadFile(localURL: URL, to remotePath: String, progress: @escaping (Double) -> Void) async throws {
        let data = try Data(contentsOf: localURL)
        files[remotePath] = data
        progress(1.0)
    }

    func createDirectory(path: String) async throws {
        directories.insert(path)
    }

    func delete(path: String) async throws {
        files.removeValue(forKey: path)
        directories.remove(path)
    }

    func move(from sourcePath: String, to destinationPath: String) async throws {
        guard let data = files.removeValue(forKey: sourcePath) else { throw StorageError.notFound }
        files[destinationPath] = data
    }

    func exists(path: String) async throws -> Bool {
        return files[path] != nil || directories.contains(path)
    }

    func testConnection() async throws -> Bool { true }
}

public func runProtocolSecurityRegressionTests() async throws {
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("🛡️ Running Protocol Security & Storage Hardening Regressions")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

    // MARK: - Test 1: S3 Multi-page Pagination & Continuation Token
    do {
        print("  ▶ [S3 Pagination] Verifying multi-page continuation token parsing...")
        let s3Client = S3StorageClient(config: S3StorageConfig(bucket: "test-bucket", accessKey: "ak", secretKey: "sk"))

        let page1XML = """
        <ListBucketResult>
            <Name>test-bucket</Name>
            <Prefix>photos/</Prefix>
            <IsTruncated>true</IsTruncated>
            <NextContinuationToken>token_for_page_2</NextContinuationToken>
            <Contents>
                <Key>photos/cat.jpg</Key>
                <Size>2048</Size>
                <ETag>"etag1"</ETag>
            </Contents>
            <CommonPrefixes>
                <Prefix>photos/2026/</Prefix>
            </CommonPrefixes>
        </ListBucketResult>
        """.data(using: .utf8)!

        let (res1, isTrunc1, token1) = s3Client.parseS3ListObjectsV2Page(xmlData: page1XML, prefix: "photos/")
        guard isTrunc1 == true else {
            throw RegressionFailure(description: "S3 parser failed to detect IsTruncated: true")
        }
        guard token1 == "token_for_page_2" else {
            throw RegressionFailure(description: "S3 parser failed to extract NextContinuationToken: got '\(token1 ?? "nil")'")
        }
        guard res1.count == 2 else {
            throw RegressionFailure(description: "Expected 2 resources on page 1, got \(res1.count)")
        }

        let page2XML = """
        <ListBucketResult>
            <Name>test-bucket</Name>
            <Prefix>photos/</Prefix>
            <IsTruncated>false</IsTruncated>
            <Contents>
                <Key>photos/dog.jpg</Key>
                <Size>4096</Size>
                <ETag>"etag2"</ETag>
            </Contents>
        </ListBucketResult>
        """.data(using: .utf8)!

        let (res2, isTrunc2, token2) = s3Client.parseS3ListObjectsV2Page(xmlData: page2XML, prefix: "photos/")
        guard isTrunc2 == false else {
            throw RegressionFailure(description: "S3 parser failed to detect IsTruncated: false")
        }
        guard token2 == nil else {
            throw RegressionFailure(description: "Expected nil continuation token on final page, got \(token2!)")
        }
        guard res2.count == 1, res2[0].displayName == "dog.jpg" else {
            throw RegressionFailure(description: "Failed to parse final page item")
        }
        print("  ✅ [S3 Pagination] PASSED: IsTruncated and NextContinuationToken parsed accurately across pages")
    }

    // MARK: - Test 2: FTP Error Propagation (Distinguishing Failure from Empty Folder)
    do {
        print("  ▶ [FTP Reliability] Verifying error propagation on network failure...")
        let ftpConfig = FTPStorageConfig(host: "127.0.0.1", port: 54321, username: "user", password: "pwd")
        let ftpClient = FTPStorageClient(config: ftpConfig)

        var caughtFTPError = false
        do {
            _ = try await ftpClient.listDirectory(path: "/nonexistent")
        } catch {
            caughtFTPError = true
        }

        guard caughtFTPError else {
            throw RegressionFailure(description: "CRITICAL: FTP listDirectory returned empty array [] instead of throwing on connection failure!")
        }
        print("  ✅ [FTP Reliability] PASSED: Network errors properly thrown rather than misreported as empty directory")
    }

    // MARK: - Test 3: Generic Copy Fallback in StorageClient Protocol
    do {
        print("  ▶ [StorageClient Copy] Verifying streaming copy fallback when native copy is absent...")
        let client = MockStorageClientWithoutNativeCopy()
        let sourceContent = "Hello Universal StorageClient Copy Fallback!".data(using: .utf8)!
        client.files["/source.txt"] = sourceContent

        // Test file copy
        try await client.copy(from: "/source.txt", to: "/dest.txt")
        guard client.files["/dest.txt"] == sourceContent else {
            throw RegressionFailure(description: "Generic copy fallback did not copy file contents properly")
        }

        // Test collision rejection (412)
        var collisionCaught = false
        do {
            try await client.copy(from: "/source.txt", to: "/dest.txt")
        } catch let err as StorageError {
            if err.statusCode == 412 || err.isPreconditionFailure {
                collisionCaught = true
            }
        }
        guard collisionCaught else {
            throw RegressionFailure(description: "Generic copy fallback allowed overwriting existing destination!")
        }

        // Test missing source (404)
        var missingCaught = false
        do {
            try await client.copy(from: "/does_not_exist.txt", to: "/dest2.txt")
        } catch let err as StorageError {
            if case .notFound = err {
                missingCaught = true
            } else if err.statusCode == 404 {
                missingCaught = true
            }
        }
        guard missingCaught else {
            throw RegressionFailure(description: "Generic copy fallback did not throw notFound for missing source!")
        }
        print("  ✅ [StorageClient Copy] PASSED: Universal download-then-upload copy succeeds with 412 collision guards")
    }

    // MARK: - Test 4: Credential Stripping from Disk & Persistent Serialization
    do {
        print("  ▶ [Credential Security] Verifying plaintext secrets are excluded from persistent disk storage...")
        let secretPass = "SuperSecretPassword-9988!"
        let testVaultId = "VaultSecurityTest-\(UUID().uuidString)"
        let config = StorageConfiguration.webdav(WebDAVStorageConfig(
            baseURL: "https://webdav.example.com/files",
            username: "security_tester",
            password: secretPass
        ))
        let vaultInfo = VaultInfo(
            id: testVaultId,
            name: "SecureVault",
            storagePath: "/files",
            createdAt: Date(),
            storageType: .webdav,
            storageConfig: config,
            isEncrypted: false
        )

        // Save active vault config
        VaultRegistry.shared.saveActiveVaultConfig(vaultInfo)
        VaultRegistry.shared.saveVaults([vaultInfo])

        // 1. Inspect ~/.clouddrive_config.json
        let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clouddrive_config.json")
        let rawConfigFile = try String(contentsOf: configURL, encoding: .utf8)
        guard !rawConfigFile.contains(secretPass) else {
            throw RegressionFailure(description: "SECURITY FLAW: Plaintext password found in ~/.clouddrive_config.json!")
        }

        // 2. Inspect UserDefaults data
        if let rawDefaultsData = UserDefaults.standard.data(forKey: "saved_vaults"),
           let rawDefaultsString = String(data: rawDefaultsData, encoding: .utf8) {
            guard !rawDefaultsString.contains(secretPass) else {
                throw RegressionFailure(description: "SECURITY FLAW: Plaintext password found in saved_vaults UserDefaults!")
            }
        }

        // 3. Verify in-memory hydration from Keychain
        guard let loadedActive = VaultRegistry.shared.loadActiveVaultConfig() else {
            throw RegressionFailure(description: "Failed to reload active vault config")
        }
        guard loadedActive.storageConfig?.secret == secretPass else {
            throw RegressionFailure(description: "Hydration failed to recover password from Keychain: got '\(loadedActive.storageConfig?.secret ?? "nil")'")
        }

        // Cleanup
        VaultRegistry.shared.clearActiveVaultConfig()
        CredentialStore.shared.deleteStoragePassword(for: testVaultId)
        print("  ✅ [Credential Security] PASSED: Plaintext passwords never written to disk, hydrated only via Keychain")
    }

    // MARK: - Test 5: Format 8 Fail-Closed JWT Verification
    do {
        print("  ▶ [JWT Fail-Closed] Verifying tampered Format 8 vault fails closed...")
        let tempBaseDir = FileManager.default.temporaryDirectory.appendingPathComponent("safetest-jwt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempBaseDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBaseDir) }

        let storageClient = LocalStorageClient()
        let vfs = VirtualFileSystem()
        vfs.configureStorage(client: storageClient)

        // Initialise genuine Format 8 vault
        let password = "TamperTestPassword123!"
        _ = try await vfs.initializeVault(name: "TamperVault", password: password, storagePath: tempBaseDir.path)

        // Tamper with vault.cryptomator
        let configPath = "\(tempBaseDir.path)/TamperVault/vault.cryptomator"
        let genuineJWT = try String(contentsOfFile: configPath, encoding: .utf8)
        let parts = genuineJWT.components(separatedBy: ".")
        guard parts.count == 3 else {
            throw RegressionFailure(description: "Genuine Format 8 JWT is not 3 parts")
        }

        // Mutate signature
        let tamperedJWT = "\(parts[0]).\(parts[1]).invalid_signature_bits"
        try tamperedJWT.write(toFile: configPath, atomically: true, encoding: .utf8)

        // Unlock must fail closed and reject tampered configuration
        let vfsUnlock = VirtualFileSystem()
        vfsUnlock.configureStorage(client: storageClient)
        var tamperedRejected = false
        do {
            try await vfsUnlock.unlockVault(password: password, storagePath: "\(tempBaseDir.path)/TamperVault", vaultId: "TamperVault")
        } catch {
            tamperedRejected = true
        }

        guard tamperedRejected else {
            throw RegressionFailure(description: "CRITICAL: Tampered Format 8 vault unlocked without failing closed!")
        }
        print("  ✅ [JWT Fail-Closed] PASSED: Tampered vault.cryptomator rejected, preventing unauthorized cipher downgrade")
    }

    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("🎉 All Protocol Security & Storage Regressions Successfully Verified!")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
}
