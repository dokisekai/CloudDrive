import Foundation
import CryptoKit
import CryptomatorCryptoLib
import CloudDriveCore
import CloudDriveStorage

func runTests() async throws {
    print("========================================")
    print("🧪 Running CloudDriveCore Test Suite")
    print("========================================")
    
    var passed = 0
    var failed = 0
    
    func assert(_ condition: Bool, _ name: String) {
        if condition {
            print("  ✅ PASS: \(name)")
            passed += 1
        } else {
            print("  ❌ FAIL: \(name)")
            failed += 1
        }
    }
    try await runBaiduPanRegressions()
    
    // 1. VFSEncryption Test
    do {
        print("\n--- Testing VFSEncryption (AES-256-GCM) ---")
        let encryption = VFSEncryption()
        let password = "SuperSecretPassword123!@#"
        let (masterKey, salt) = try encryption.generateMasterKey(password: password)
        
        let originalText = "Hello, on-demand encrypted cloud storage with Cryptomator style!"
        let originalData = Data(originalText.utf8)
        
        // Encrypt data
        let encryptedData = try encryption.encrypt(data: originalData, key: masterKey)
        assert(encryptedData != originalData, "Encrypted data differs from original")
        
        // Derive key again
        let derivedKey = try encryption.deriveMasterKey(password: password, salt: salt)
        let decryptedData = try encryption.decrypt(data: encryptedData, key: derivedKey)
        let decryptedText = String(data: decryptedData, encoding: .utf8)
        assert(decryptedText == originalText, "Decrypted data matches original text")
        
        // Test MasterkeyFile with password verification
        let mkData = try MasterkeyFile.lock(masterkey: masterKey, vaultVersion: 8, passphrase: password)
        let unlockedMk = try MasterkeyFile.withContentFromData(data: mkData).unlock(passphrase: password)
        assert(unlockedMk.rawKey == masterKey.rawKey, "Masterkey unlocked matches original")
        
        var wrongPasswordFailed = false
        do {
            _ = try MasterkeyFile.withContentFromData(data: mkData).unlock(passphrase: "WrongPassword456")
        } catch {
            wrongPasswordFailed = true
        }
        assert(wrongPasswordFailed, "Masterkey with wrong password throws error")
        
        // Directory ID encryption (deterministic)
        let dirId = "ROOT_DOCUMENTS_2026"
        let encDirId1 = try encryption.encryptDirectoryId(dirId, key: masterKey)
        let encDirId2 = try encryption.encryptDirectoryId(dirId, key: masterKey)
        assert(!encDirId1.isEmpty, "Directory ID encrypted is non-empty")
        assert(encDirId1 == encDirId2, "Directory ID encryption is deterministic")
    } catch {
        print("❌ Unexpected error in encryption tests: \(error)")
        failed += 1
    }
    
    // 2. VaultInfo Serialization Test
    do {
        print("\n--- Testing VaultInfo Dual-Mode Serialization ---")
        let directVault = VaultInfo(
            id: "vault-direct-001",
            name: "Direct WebDAV",
            storagePath: "/",
            createdAt: Date(),
            webdavURL: "https://dav.example.com",
            webdavUsername: "admin",
            isMounted: true,
            isEncrypted: false
        )
        
        let directEncoded = try JSONEncoder().encode(directVault)
        let directDecoded = try JSONDecoder().decode(VaultInfo.self, from: directEncoded)
        assert(directDecoded.id == directVault.id, "Direct vault ID preserved")
        assert(directDecoded.isEncrypted == false, "Direct vault isEncrypted is false")
        
        let encVault = VaultInfo(
            id: "vault-enc-001",
            name: "AES Encrypted Vault",
            storagePath: "/",
            createdAt: Date(),
            webdavURL: "https://dav.example.com",
            webdavUsername: "admin",
            isMounted: true,
            isEncrypted: true
        )
        
        let encEncoded = try JSONEncoder().encode(encVault)
        let encDecoded = try JSONDecoder().decode(VaultInfo.self, from: encEncoded)
        assert(encDecoded.id == encVault.id, "Encrypted vault ID preserved")
        assert(encDecoded.isEncrypted == true, "Encrypted vault isEncrypted is true")
    } catch {
        print("❌ Unexpected error in VaultInfo tests: \(error)")
        failed += 1
    }
    
    // 3. VirtualFileSystem On-Demand Engine Test
    do {
        print("\n--- Testing VirtualFileSystem Mode Switching ---")
        let vfs = VirtualFileSystem.shared
        vfs.configureWebDAV(baseURL: URL(string: "https://dav.example.com")!, username: "testuser", password: "testpassword")
        
        // Test direct mapping initialization
        try await vfs.initializeDirectMappingVault(vaultId: "direct-vault-test", storagePath: "/")
        assert(!vfs.isEncrypted, "Direct mapping vault is not marked encrypted")
        assert(vfs.isVaultMounted(vaultId: "direct-vault-test"), "Direct mapping vault reports mounted")
        
        vfs.lock()
        assert(!vfs.isVaultMounted(vaultId: "direct-vault-test"), "VFS lock resets mounted vault ID")
    } catch {
        print("❌ Unexpected error in VirtualFileSystem tests: \(error)")
        failed += 1
    }
    
    // 4. VirtualFileSystem Encrypted Vault Lifecycle Test
    do {
        print("\n--- Testing VirtualFileSystem Encrypted Vault Lifecycle ---")
        let vfs = VirtualFileSystem.shared
        let localClient = LocalStorageClient()
        let tempStorageDir = FileManager.default.temporaryDirectory.appendingPathComponent("vault_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempStorageDir, withIntermediateDirectories: true)
        
        vfs.configureStorage(client: localClient)
        
        let vaultPassword = "MySecretVaultPassword123"
        let vaultId = try await vfs.initializeVault(name: "TestVault", password: vaultPassword, storagePath: tempStorageDir.path)
        assert(!vaultId.isEmpty, "Encrypted vault initialized with valid ID")
        assert(vfs.isEncrypted, "VFS is in encrypted mode")
        assert(vfs.isVaultMounted(vaultId: vaultId), "Encrypted vault is mounted")
        
        // Lock vault
        vfs.lock()
        assert(!vfs.isEncrypted, "VFS is no longer in encrypted mode after lock")
        assert(!vfs.isVaultMounted(vaultId: vaultId), "Vault is no longer mounted after lock")
        
        // Unlock vault
        try await vfs.unlockVault(password: vaultPassword, storagePath: tempStorageDir.path, vaultId: vaultId)
        assert(vfs.isEncrypted, "VFS is in encrypted mode after unlock")
        assert(vfs.isVaultMounted(vaultId: vaultId), "Vault is mounted after unlock")
        
        // Test unlocking with wrong password fails
        vfs.lock()
        var wrongPassFailed = false
        do {
            try await vfs.unlockVault(password: "IncorrectPassword456", storagePath: tempStorageDir.path, vaultId: vaultId)
        } catch {
            wrongPassFailed = true
        }
        assert(wrongPassFailed, "Unlocking vault with wrong password throws error")
        
        // Clean up
        vfs.lock()
        try? FileManager.default.removeItem(at: tempStorageDir)
    } catch {
        print("❌ Unexpected error in encrypted vault lifecycle tests: \(error)")
        failed += 1
    }
    
    // 5. Encrypted File Upload / Download / Directory Test
    do {
        print("\n--- Testing Encrypted File Upload & Directory Operations ---")
        let vfs = VirtualFileSystem.shared
        let localClient = LocalStorageClient()
        let tempStorageDir = FileManager.default.temporaryDirectory.appendingPathComponent("vault_ops_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempStorageDir, withIntermediateDirectories: true)
        
        vfs.configureStorage(client: localClient)
        let vaultPassword = "OpsSecretPassword123!"
        let vaultId = try await vfs.initializeVault(name: "OpsVault", password: vaultPassword, storagePath: tempStorageDir.path)
        
        // Create encrypted directory
        let dirItem = try await vfs.createDirectory(name: "TestFolder", parentId: "ROOT")
        assert(dirItem.name == "TestFolder", "Encrypted directory created with correct name")
        assert(dirItem.isDirectory == true, "Created directory is marked as directory")
        
        // Upload file to ROOT
        let localSrcFile = FileManager.default.temporaryDirectory.appendingPathComponent("upload_test_\(UUID().uuidString).txt")
        let testContent = "Confidential payload encrypted with Cryptomator Format 8!"
        try testContent.write(to: localSrcFile, atomically: true, encoding: .utf8)
        
        let fileItem = try await vfs.uploadFile(localURL: localSrcFile, name: "SecretDoc.txt", parentId: "ROOT")
        assert(fileItem.name == "SecretDoc.txt", "Encrypted file uploaded with cleartext name")
        assert(fileItem.size == Int64(testContent.utf8.count), "Encrypted file item size matches cleartext size")
        
        // Upload file into subdirectory
        let subFileItem = try await vfs.uploadFile(localURL: localSrcFile, name: "SubDoc.txt", parentId: dirItem.id)
        assert(subFileItem.name == "SubDoc.txt", "Encrypted file in subdirectory uploaded")
        
        // List root directory
        let rootItems = try await vfs.listDirectoryFromWebDAVAsync(directoryId: "ROOT")
        assert(rootItems.contains(where: { $0.name == "TestFolder" }), "Root contains TestFolder")
        assert(rootItems.contains(where: { $0.name == "SecretDoc.txt" }), "Root contains SecretDoc.txt")
        
        // Download and verify content
        let downloadedURL = FileManager.default.temporaryDirectory.appendingPathComponent("downloaded_\(UUID().uuidString).txt")
        try await vfs.downloadFile(fileId: fileItem.id, to: downloadedURL)
        let downloadedContent = try String(contentsOf: downloadedURL, encoding: .utf8)
        assert(downloadedContent == testContent, "Decrypted downloaded file content matches original")
        
        // Clean up
        try? FileManager.default.removeItem(at: localSrcFile)
        try? FileManager.default.removeItem(at: downloadedURL)
        vfs.lock()
        try? FileManager.default.removeItem(at: tempStorageDir)
    } catch {
        print("❌ Unexpected error in encrypted upload/download tests: \(error)")
        failed += 1
    }
    
    // 5. Cryptomator Format 8 JWT and Cryptomator Interoperability Tests
    do {
        print("\n--- Testing Cryptomator Format 8 JWT Specification ---")
        let masterKey = try Masterkey.createNew()
        let (config, jwtData) = try CryptomatorVaultConfig.create(masterKey: masterKey, cipherCombo: "SIV_GCM", shorteningThreshold: 220)
        let jwtString = String(data: jwtData, encoding: .utf8)!
        
        assert(jwtString.components(separatedBy: ".").count == 3, "JWT has 3 dot-separated parts")
        assert(config.header.kid == "masterkeyfile:masterkey.cryptomator", "JWT header kid points to masterkeyfile")
        assert(config.header.typ == "JWT", "JWT header typ is JWT")
        assert(config.header.alg == "HS256", "JWT header alg is HS256")
        assert(config.payload.format == 8, "JWT payload format is 8")
        assert(config.payload.cipherCombo == "SIV_GCM", "JWT payload cipherCombo is SIV_GCM")
        assert(config.payload.shorteningThreshold == 220, "JWT payload shorteningThreshold is 220")
        
        // Verify signature with correct key
        assert(config.verifySignature(masterKey: masterKey), "JWT signature verified with masterKey rawKey")
        
        // Tamper test: other key must fail
        let wrongKey = try Masterkey.createNew()
        assert(!config.verifySignature(masterKey: wrongKey), "JWT signature fails with wrong key")
        
        // Decode unverified
        let parsed = try CryptomatorVaultConfig.decodeUnverified(jwtString: jwtString)
        assert(parsed.payload.format == 8, "Parsed unverified payload format matches")
        assert(parsed.verifySignature(masterKey: masterKey), "Parsed config signature verifies successfully")
    } catch {
        print("❌ Unexpected error in Cryptomator Format 8 JWT tests: \(error)")
        failed += 1
    }
    
    // 6. Cryptomator Format 8 Vault Lifecycle & Unlock Test
    do {
        print("\n--- Testing Cryptomator Format 8 Vault Initialization & Unlock ---")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("cm_format8_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let localClient = LocalStorageClient()
        localClient.configureSecurityScope(url: tempDir)
        let vfs = VirtualFileSystem.shared
        vfs.configureStorage(client: localClient)
        
        let password = "CryptomatorCompatible2026!"
        let vaultId = try await vfs.initializeVault(name: "MyFormat8Vault", password: password, storagePath: tempDir.path)
        
        // Verify files on storage
        let vaultPath = "\(tempDir.path)/\(vaultId)"
        let hasConfig = try await localClient.exists(path: "\(vaultPath)/vault.cryptomator")
        let hasMK = try await localClient.exists(path: "\(vaultPath)/masterkey.cryptomator")
        let hasD = try await localClient.exists(path: "\(vaultPath)/d")
        
        assert(hasConfig, "vault.cryptomator exists on storage")
        assert(hasMK, "masterkey.cryptomator exists on storage")
        assert(hasD, "d directory exists on storage")
        
        // Verify vault.cryptomator is standard JWT
        let configURL = URL(fileURLWithPath: "\(vaultPath)/vault.cryptomator")
        let configContent = try String(contentsOf: configURL, encoding: .utf8)
        let decodedConfig = try CryptomatorVaultConfig.decodeUnverified(jwtString: configContent)
        assert(decodedConfig.payload.format == 8, "Created vault is Cryptomator Format 8")
        
        // Lock and unlock vault
        vfs.lock()
        assert(vfs.isEncrypted == false, "VFS is locked")
        
        try await vfs.unlockVault(password: password, storagePath: "\(tempDir.path)/\(vaultId)", vaultId: vaultId)
        assert(vfs.isEncrypted == true, "VFS successfully unlocked Format 8 vault")
        
        vfs.lock()
        try? FileManager.default.removeItem(at: tempDir)
    } catch {
        print("❌ Unexpected error in Cryptomator Format 8 lifecycle tests: \(error)")
        failed += 1
    }
    
    // 7. Cryptomator Format 7 Interoperability Test
    do {
        print("\n--- Testing Cryptomator Format 7 Interoperability (SIV_CTRMAC fallback) ---")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("cm_format7_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let localClient = LocalStorageClient()
        localClient.configureSecurityScope(url: tempDir)
        let vfs = VirtualFileSystem.shared
        vfs.configureStorage(client: localClient)
        
        let password = "OldFormat7Password!"
        let masterKey = try Masterkey.createNew()
        
        // Create Format 7 masterkey (version 7, no vault.cryptomator JWT)
        let mkData = try MasterkeyFile.lock(masterkey: masterKey, vaultVersion: 7, passphrase: password)
        let mkURL = tempDir.appendingPathComponent("masterkey.cryptomator")
        try mkData.write(to: mkURL)
        
        // Create d directory
        let dURL = tempDir.appendingPathComponent("d")
        try FileManager.default.createDirectory(at: dURL, withIntermediateDirectories: true)
        
        // Unlock Format 7 vault
        let vaultId = "format7_test"
        try await vfs.unlockVault(password: password, storagePath: tempDir.path, vaultId: vaultId)
        assert(vfs.isEncrypted == true, "Format 7 vault successfully unlocked")
        
        vfs.lock()
        try? FileManager.default.removeItem(at: tempDir)
    } catch {
        print("❌ Unexpected error in Cryptomator Format 7 interoperability test: \(error)")
        failed += 1
    }
    
    // 8. Cryptomator Name Shortening (.c9s) Test
    do {
        print("\n--- Testing Cryptomator Name Shortening (.c9s) ---")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("cm_c9s_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let localClient = LocalStorageClient()
        localClient.configureSecurityScope(url: tempDir)
        let masterKey = try Masterkey.createNew()
        
        // Set shorteningThreshold to 40 so test filenames trigger .c9s
        let format = CryptomatorFormat(masterkey: masterKey, storageClient: localClient, basePath: tempDir.path, scheme: .sivGcm, shorteningThreshold: 40)
        
        // Root directory
        let rootDir = try format.getDirPath(dirId: Data([]))
        try await localClient.createDirectory(path: rootDir)
        
        // Create a file with a name long enough to exceed threshold 40
        let longFileName = "VeryLongDocumentNameThatDefinitelyExceedsFortyCharactersWhenEncrypted.pdf"
        let sampleContent = "Content inside long filename document."
        let tempSampleURL = FileManager.default.temporaryDirectory.appendingPathComponent("long_\(UUID().uuidString).pdf")
        try sampleContent.write(to: tempSampleURL, atomically: true, encoding: .utf8)
        
        let uploadedItem = try await format.uploadFile(localURL: tempSampleURL, name: longFileName, parentDirId: Data([]))
        assert(uploadedItem.name == longFileName, "Uploaded item cleartext name matches")
        
        guard let remotePath = uploadedItem.remotePath else {
            fatalError("uploadedItem remotePath is nil")
        }
        assert(remotePath.contains(".c9s/contents.c9r"), "Shortened file remote path contains .c9s/contents.c9r")
        
        // Verify .c9s directory contains name.c9s
        let shortenedDir = (remotePath as NSString).deletingLastPathComponent
        let hasNameC9s = try await localClient.exists(path: "\(shortenedDir)/name.c9s")
        assert(hasNameC9s, "Shortened directory contains name.c9s mapping file")
        
        // Verify listDirectory inflates .c9s back to cleartext name
        let listedItems = try await format.listDirectory(dirId: Data([]))
        let found = listedItems.first(where: { $0.name == longFileName })
        assert(found != nil, "listDirectory successfully inflates .c9s item")
        assert(found?.size == Int64(sampleContent.utf8.count), "listDirectory correctly calculates cleartext size for .c9s item")
        
        // Download and verify content
        let downloadedURL = FileManager.default.temporaryDirectory.appendingPathComponent("down_c9s_\(UUID().uuidString).pdf")
        try await format.downloadFile(remotePath: remotePath, to: downloadedURL)
        let downloadedStr = try String(contentsOf: downloadedURL, encoding: .utf8)
        assert(downloadedStr == sampleContent, "Downloaded content of .c9s file matches original")
        
        // Test delete shortened item
        try await format.deleteItem(remotePath: remotePath, dirIdData: nil)
        let existsAfterDelete = try await localClient.exists(path: shortenedDir)
        assert(!existsAfterDelete, "Deleting .c9s item completely deletes the shortened directory")
        
        try? FileManager.default.removeItem(at: tempSampleURL)
        try? FileManager.default.removeItem(at: downloadedURL)
        try? FileManager.default.removeItem(at: tempDir)
    } catch {
        print("❌ Unexpected error in name shortening tests: \(error)")
        failed += 1
    }
    
    // LocalWebDAVServer Test
    do {
        print("\n--- Testing LocalWebDAVServer (Loopback Bridge) ---")
        let server = LocalWebDAVServer.shared
        server.start()
        
        let tempTestDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_local_webdav_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempTestDir, withIntermediateDirectories: true)
        
        // Write a test file
        let testFileName = "test_file.txt"
        let testContent = "Hello from LocalWebDAVServer!"
        let testFileURL = tempTestDir.appendingPathComponent(testFileName)
        try testContent.write(to: testFileURL, atomically: true, encoding: .utf8)
        
        // Register vault
        let testVaultId = "test_vault_\(UUID().uuidString.prefix(6))"
        server.register(vaultId: testVaultId, localURL: tempTestDir)
        
        let vaultBaseURL = server.baseURL(for: testVaultId)
        assert(vaultBaseURL.absoluteString.contains("127.0.0.1"), "Server baseURL points to 127.0.0.1")
        
        // Connect WebDAVClient
        let client = WebDAVClient()
        client.configure(baseURL: vaultBaseURL, username: "local", password: "local")
        
        // Test OPTIONS (testConnection)
        let canConnect = try await client.testConnection()
        assert(canConnect, "WebDAVClient connects to LocalWebDAVServer")
        
        // Test listDirectory (PROPFIND Depth 1)
        let items = try await client.listDirectory(path: "/")
        assert(items.contains(where: { $0.displayName == testFileName }), "listDirectory finds test_file.txt")
        
        // Test downloadFile (GET)
        let downloadDest = FileManager.default.temporaryDirectory.appendingPathComponent("downloaded_\(UUID().uuidString).txt")
        try await client.downloadFile(path: "/\(testFileName)", to: downloadDest, progress: { _ in })
        let downloadedStr = try String(contentsOf: downloadDest, encoding: .utf8)
        assert(downloadedStr == testContent, "downloadFile downloaded exact content")
        
        // Test uploadFile (PUT)
        let uploadSrc = FileManager.default.temporaryDirectory.appendingPathComponent("upload_\(UUID().uuidString).txt")
        let uploadedContent = "Uploaded via LocalWebDAVServer PUT!"
        try uploadedContent.write(to: uploadSrc, atomically: true, encoding: .utf8)
        try await client.uploadFile(localURL: uploadSrc, to: "/new_upload.txt", progress: { _ in })
        
        let localCreatedFile = tempTestDir.appendingPathComponent("new_upload.txt")
        assert(FileManager.default.fileExists(atPath: localCreatedFile.path), "uploadFile created file on local filesystem")
        let localCreatedContent = try String(contentsOf: localCreatedFile, encoding: .utf8)
        assert(localCreatedContent == uploadedContent, "Uploaded file content matches")
        
        // Test delete (DELETE)
        try await client.delete(path: "/new_upload.txt")
        assert(!FileManager.default.fileExists(atPath: localCreatedFile.path), "delete removed file on local filesystem")
        
        // Test move / rename (MOVE)
        try await client.move(from: "/\(testFileName)", to: "/renamed_file.txt")
        let renamedLocalFile = tempTestDir.appendingPathComponent("renamed_file.txt")
        let originalLocalFile = tempTestDir.appendingPathComponent(testFileName)
        assert(FileManager.default.fileExists(atPath: renamedLocalFile.path), "move renamed file on local filesystem")
        assert(!FileManager.default.fileExists(atPath: originalLocalFile.path), "move removed original file on local filesystem")
        
        // Test VFS direct mapping moveItem
        let vfs = VirtualFileSystem(vaultId: testVaultId)
        vfs.configureWebDAV(baseURL: vaultBaseURL, username: "local", password: "local")
        try await vfs.initializeDirectMappingVault(vaultId: testVaultId, storagePath: "/")
        
        // Preload directory into VFS database
        _ = try await vfs.listDirectoryFromWebDAVAsync(directoryId: "ROOT")
        let itemBeforeMove = try vfs.getItem(id: "/renamed_file.txt")
        assert(itemBeforeMove != nil, "vfs.getItem finds /renamed_file.txt in database")
        
        // Perform moveItem via VFS
        let movedVfsItem = try await vfs.moveItem(itemId: "/renamed_file.txt", newParentId: "ROOT", newName: "final_moved.txt")
        assert(movedVfsItem.id == "/final_moved.txt", "vfs.moveItem returns correct new ID")
        assert(movedVfsItem.name == "final_moved.txt", "vfs.moveItem returns correct new name")
        
        let finalLocalFile = tempTestDir.appendingPathComponent("final_moved.txt")
        assert(FileManager.default.fileExists(atPath: finalLocalFile.path), "vfs.moveItem updated local storage")
        
        let itemAfterMove = try vfs.getItem(id: "/final_moved.txt")
        assert(itemAfterMove != nil, "vfs.getItem finds moved file in database")
        let oldItemAfterMove = try vfs.getItem(id: "/renamed_file.txt")
        assert(oldItemAfterMove == nil, "old file record deleted from database")
        
        // Test createDirectory
        let subfolderItem = try await vfs.createDirectory(name: "subfolder", parentId: "ROOT")
        assert(subfolderItem.isDirectory, "vfs.createDirectory creates directory item")
        let subfolderLocal = tempTestDir.appendingPathComponent("subfolder")
        assert(FileManager.default.fileExists(atPath: subfolderLocal.path), "subfolder created on local filesystem")
        
        // Test moveItem into subdirectory
        let movedIntoSub = try await vfs.moveItem(itemId: "/final_moved.txt", newParentId: "/subfolder", newName: nil)
        assert(movedIntoSub.id == "/subfolder/final_moved.txt", "moved item into subfolder has correct ID")
        assert(movedIntoSub.parentId == "/subfolder", "moved item has correct subfolder parentId")
        let fileInSubLocal = subfolderLocal.appendingPathComponent("final_moved.txt")
        assert(FileManager.default.fileExists(atPath: fileInSubLocal.path), "file exists in subfolder on local filesystem")
        assert(!FileManager.default.fileExists(atPath: finalLocalFile.path), "old root file removed from local filesystem")
        
        // Test rename directory
        let renamedDir = try await vfs.moveItem(itemId: "/subfolder", newParentId: "ROOT", newName: "renamed_subfolder")
        assert(renamedDir.id == "/renamed_subfolder", "renamed directory has correct new ID")
        assert(renamedDir.name == "renamed_subfolder", "renamed directory has correct new name")
        let renamedDirLocal = tempTestDir.appendingPathComponent("renamed_subfolder")
        assert(FileManager.default.fileExists(atPath: renamedDirLocal.path), "renamed directory exists on filesystem")
        assert(!FileManager.default.fileExists(atPath: subfolderLocal.path), "old directory path removed from filesystem")
        
        // Test delete directory
        try await vfs.delete(itemId: "/renamed_subfolder")
        assert(!FileManager.default.fileExists(atPath: renamedDirLocal.path), "deleted directory removed from filesystem")
        let deletedDirRecord = try vfs.getItem(id: "/renamed_subfolder")
        assert(deletedDirRecord == nil, "deleted directory record removed from database")
        
        // Clean up
        server.unregister(vaultId: testVaultId)
        server.stop()
        try? FileManager.default.removeItem(at: tempTestDir)
        try? FileManager.default.removeItem(at: downloadDest)
        try? FileManager.default.removeItem(at: uploadSrc)
    } catch {
        print("❌ Unexpected error in LocalWebDAVServer tests: \(error)")
        failed += 1
    }
    
    // 8. Multi-Protocol Cloud Storage Tests (S3, SMB, FTP, WebDAV, Local)
    do {
        print("\n--- Testing Multi-Protocol Cloud Storage Suite ---")
        
        // 8.1 StorageType and Configuration Serialization
        let webdavConfig = WebDAVStorageConfig(baseURL: "https://dav.example.com", username: "user", password: "pwd")
        let s3Config = S3StorageConfig(endpoint: "https://s3.amazonaws.com", region: "us-east-1", bucket: "test-bucket", accessKey: "AKIA123", secretKey: "sec456", usePathStyle: false, rootPrefix: "myvault")
        let smbConfig = SMBStorageConfig(host: "192.168.1.100", share: "Public", path: "/docs", username: "admin", password: "pwd", domain: "WORKGROUP", port: 445)
        let ftpConfig = FTPStorageConfig(host: "ftp.example.com", port: 21, username: "ftpuser", password: "ftppassword", path: "/home", useTLS: true)
        let localConfig = LocalStorageConfig(path: "/tmp/local_test")
        
        assert(StorageType.webdav.displayName == "WebDAV", "StorageType WebDAV displayName")
        assert(StorageType.s3.displayName.contains("S3"), "StorageType S3 displayName")
        assert(StorageType.smb.displayName.contains("SMB"), "StorageType SMB displayName")
        assert(StorageType.ftp.displayName.contains("FTP"), "StorageType FTP displayName")
        
        // Test JSON Codable
        let s3EnumConfig = StorageConfiguration.s3(s3Config)
        let encodedS3 = try JSONEncoder().encode(s3EnumConfig)
        let decodedS3 = try JSONDecoder().decode(StorageConfiguration.self, from: encodedS3)
        assert(decodedS3.type == .s3, "StorageConfiguration S3 decodes correctly")
        
        let smbEnumConfig = StorageConfiguration.smb(smbConfig)
        let encodedSMB = try JSONEncoder().encode(smbEnumConfig)
        let decodedSMB = try JSONDecoder().decode(StorageConfiguration.self, from: encodedSMB)
        assert(decodedSMB.type == .smb, "StorageConfiguration SMB decodes correctly")
        
        let ftpEnumConfig = StorageConfiguration.ftp(ftpConfig)
        let encodedFTP = try JSONEncoder().encode(ftpEnumConfig)
        let decodedFTP = try JSONDecoder().decode(StorageConfiguration.self, from: encodedFTP)
        assert(decodedFTP.type == .ftp, "StorageConfiguration FTP decodes correctly")
        
        // 8.2 StorageClientFactory Creation
        let webdavClient = StorageClientFactory.createClient(configuration: .webdav(webdavConfig))
        assert(webdavClient is WebDAVStorageClient, "Factory creates WebDAVStorageClient")
        
        let s3Client = StorageClientFactory.createClient(configuration: s3EnumConfig)
        assert(!(s3Client is WebDAVStorageClient), "Factory creates disabled non-WebDAV client for S3")
        
        let smbClient = StorageClientFactory.createClient(configuration: smbEnumConfig)
        assert(!(smbClient is WebDAVStorageClient), "Factory creates disabled non-WebDAV client for SMB")
        
        let ftpClient = StorageClientFactory.createClient(configuration: ftpEnumConfig)
        assert(!(ftpClient is WebDAVStorageClient), "Factory creates disabled non-WebDAV client for FTP")
        
        let localClient = StorageClientFactory.createClient(configuration: .local(localConfig))
        assert(!(localClient is WebDAVStorageClient), "Factory creates disabled non-WebDAV client for Local")
        
        // 8.3 VaultInfo Multi-Protocol & Backward Compatibility
        let s3Vault = VaultInfo(
            id: "s3_vault_001",
            name: "My S3 Vault",
            storagePath: "/",
            createdAt: Date(),
            storageType: .s3,
            storageConfig: s3EnumConfig,
            isMounted: true,
            isEncrypted: true
        )
        let encodedVault = try JSONEncoder().encode(s3Vault)
        let decodedVault = try JSONDecoder().decode(VaultInfo.self, from: encodedVault)
        assert(decodedVault.storageType == .s3, "VaultInfo storageType preserved across serialization")
        assert(!decodedVault.isLocal, "S3 vault is not local")
        
        // Legacy JSON string without storageType (must fallback to WebDAV)
        let legacyJSON = """
        {
            "id": "legacy_001",
            "name": "Legacy WebDAV",
            "storagePath": "/",
            "createdAt": 1727880000,
            "webdavURL": "https://dav.test.com",
            "webdavUsername": "legacyuser",
            "isEncrypted": false
        }
        """.data(using: .utf8)!
        let legacyVault = try JSONDecoder().decode(VaultInfo.self, from: legacyJSON)
        assert(legacyVault.storageType == .webdav, "Legacy vault without storageType defaults to .webdav")
        assert(!legacyVault.isLocal, "Legacy WebDAV vault correctly recognized as non-local")
        
        // 8.4 Non-WebDAV Protocol Operation Rejection Checks
        var s3Rejected = false
        do { _ = try await s3Client.exists(path: "/") } catch StorageError.notSupported { s3Rejected = true } catch {}
        assert(s3Rejected, "S3 operations correctly rejected when WebDAV-only enabled")

        var smbRejected = false
        do { _ = try await smbClient.listDirectory(path: "/") } catch StorageError.notSupported { smbRejected = true } catch {}
        assert(smbRejected, "SMB operations correctly rejected when WebDAV-only enabled")

        var ftpRejected = false
        do { _ = try await ftpClient.testConnection() } catch StorageError.notSupported { ftpRejected = true } catch {}
        assert(ftpRejected, "FTP operations correctly rejected when WebDAV-only enabled")
        
        // 8.5 VFS configured with StorageConfiguration
        let uniqueVaultId = "multi_proto_\(UUID().uuidString.prefix(8))"
        let multiVFS = VirtualFileSystem(vaultId: uniqueVaultId)
        multiVFS.configureStorage(configuration: .webdav(webdavConfig))
        assert(multiVFS.getStorageClient() is WebDAVStorageClient, "VFS configureStorage sets WebDAV storageClient")
    } catch {
        print("❌ Unexpected error in Multi-Protocol tests: \(error)")
        failed += 1
    }
    
    // 13. IgnoreRuleEngine & ThumbnailManager Test Suite
    do {
        print("\n--- Testing IgnoreRuleEngine & Multi-Media Thumbnail Support ---")
        let engine = IgnoreRuleEngine.shared
        
        // 13.1 Builtin rules
        assert(engine.shouldIgnore(path: ".DS_Store", name: ".DS_Store", isDirectory: false, vaultId: "v1"), "Builtin .DS_Store ignored")
        assert(engine.shouldIgnore(path: "some/sub/folder/.DS_Store", name: ".DS_Store", isDirectory: false, vaultId: "v1"), "Subdirectory .DS_Store ignored")
        assert(engine.shouldIgnore(path: "Thumbs.db", name: "Thumbs.db", isDirectory: false, vaultId: "v1"), "Builtin Windows Thumbs.db ignored")
        
        // 13.2 Global patterns
        engine.setGlobalPatterns(["target/", "node_modules/", "*.pyc", "!important.pyc"])
        assert(engine.shouldIgnore(path: "target", name: "target", isDirectory: true, vaultId: "v1"), "Global rule target/ matches directory")
        assert(engine.shouldIgnore(path: "my-app/target/debug/build.o", name: "build.o", isDirectory: false, vaultId: "v1"), "Global rule target/ matches nested build artifacts")
        assert(engine.shouldIgnore(path: "frontend/node_modules/lodash/index.js", name: "index.js", isDirectory: false, vaultId: "v1"), "Global rule node_modules/ matches dependencies")
        assert(engine.shouldIgnore(path: "test.pyc", name: "test.pyc", isDirectory: false, vaultId: "v1"), "Global rule *.pyc matches python bytecode")
        assert(!engine.shouldIgnore(path: "important.pyc", name: "important.pyc", isDirectory: false, vaultId: "v1"), "Global negation rule !important.pyc restores item")
        
        // 13.3 Vault-level rules (from .clouddriveignore)
        engine.setVaultRules(vaultId: "vault_alpha", content: """
        # custom vault ignore
        my_secret_folder/
        *.vaultonly
        """)
        assert(engine.shouldIgnore(path: "my_secret_folder", name: "my_secret_folder", isDirectory: true, vaultId: "vault_alpha"), "Vault-level rule matches for vault_alpha")
        assert(!engine.shouldIgnore(path: "my_secret_folder", name: "my_secret_folder", isDirectory: true, vaultId: "vault_beta"), "Vault-level rule does NOT leak to vault_beta")
        assert(!engine.shouldIgnore(path: ".clouddriveignore", name: ".clouddriveignore", isDirectory: false, vaultId: "vault_alpha"), ".clouddriveignore file itself is NEVER ignored")
        
        // 13.4 User Finder Manual Exclusion
        engine.setUserExcluded(vaultId: "vault_alpha", path: "docs/manual_excluded_dir", isExcluded: true)
        assert(engine.shouldIgnore(path: "docs/manual_excluded_dir", name: "manual_excluded_dir", isDirectory: true, vaultId: "vault_alpha"), "User manually excluded directory ignored")
        assert(engine.shouldIgnore(path: "docs/manual_excluded_dir/child.txt", name: "child.txt", isDirectory: false, vaultId: "vault_alpha"), "Sub-items under user manually excluded directory ignored")
        
        // 13.5 ThumbnailManager multimedia format support
        let isVid = ThumbnailManager.isVideo(extension: "mp4") && ThumbnailManager.isVideo(extension: "mov") && ThumbnailManager.isVideo(extension: "mkv")
        let isDoc = ThumbnailManager.isDocument(extension: "pdf")
        let isImg = ThumbnailManager.isImage(extension: "png") && ThumbnailManager.isImage(extension: "jpg") && ThumbnailManager.isImage(extension: "heic")
        let isTxtNotVid = !ThumbnailManager.isVideo(extension: "txt")
        assert(isVid && isDoc && isImg && isTxtNotVid, "ThumbnailManager multimedia formats recognized correctly")
        
        // 13.6 ThumbnailCatalog Binary Serialization & Deserialization
        let catalog = ThumbnailCatalog()
        let fakeThumb1 = "PNG_SAMPLE_DATA_1".data(using: .utf8)!
        let fakeThumb2 = "JPG_SAMPLE_DATA_2".data(using: .utf8)!
        catalog.addOrUpdate(filename: "photo1.png", fileId: "id_photo_1", imageData: fakeThumb1, timestamp: 1700000000, width: 256, height: 256)
        catalog.addOrUpdate(filename: "video1.mp4", fileId: "id_video_1", imageData: fakeThumb2, timestamp: 1700000001, width: 512, height: 288)
        
        let catalogData = catalog.serialize()
        assert(catalogData.count > 0, "ThumbnailCatalog serialized into non-empty binary data")
        
        let restoredCatalog = ThumbnailCatalog.deserialize(from: catalogData)
        assert(restoredCatalog != nil, "ThumbnailCatalog successfully deserialized from binary data")
        assert(restoredCatalog?.count == 2, "Restored catalog contains exactly 2 entries")
        assert(restoredCatalog?.getImageData(forFileId: "id_photo_1") == fakeThumb1, "Restored entry 1 data matches byte-for-byte")
        assert(restoredCatalog?.getImageData(forFilename: "video1.mp4") == fakeThumb2, "Restored entry 2 data matches byte-for-byte")
        assert(engine.shouldIgnore(path: ".thumbnails.catalog", name: ".thumbnails.catalog", isDirectory: false, vaultId: "v1"), ".thumbnails.catalog is hidden by default ignore rules")
        
        // 13.7 DirectoryThumbnailCatalogManager Local Recording & Lookup
        let catalogVFS = VirtualFileSystem(vaultId: "catalog_test_vault")
        let catalogManager = DirectoryThumbnailCatalogManager.shared
        catalogManager.recordThumbnail(
            directoryId: "dir_test_123",
            filename: "doc.pdf",
            fileId: "file_pdf_999",
            imageData: "PDF_PREVIEW_DATA".data(using: .utf8)!,
            timestamp: 1700000002,
            width: 300,
            height: 400,
            vfs: catalogVFS
        )
        let retrievedData = catalogManager.getThumbnailData(directoryId: "dir_test_123", fileId: "file_pdf_999")
        assert(retrievedData == "PDF_PREVIEW_DATA".data(using: .utf8)!, "DirectoryThumbnailCatalogManager immediately retrieves recorded thumbnail")
    }
    
    // 14. Cache Architecture & Eviction Improvements Test Suite
    do {
        print("\n--- Testing Cache Architecture Improvements (Eviction, Quota, Streaming & Stale Checks) ---")
        
        // 14.1 Configurable maxCacheSize
        let cacheMgr = CacheManager.shared
        let originalQuota = cacheMgr.maxCacheSize
        cacheMgr.maxCacheSize = 25 * 1024 * 1024 * 1024
        assert(cacheMgr.maxCacheSize == 25 * 1024 * 1024 * 1024, "CacheManager maxCacheSize successfully updated to 25GB")
        cacheMgr.maxCacheSize = originalQuota
        
        // 14.2 Evict file sets syncStatus to .cloudOnly
        let testEvictId = "test_evict_\(UUID().uuidString).txt"
        let testTempURL = FileManager.default.temporaryDirectory.appendingPathComponent(testEvictId)
        try "CACHE_SAMPLE_CONTENT".data(using: .utf8)?.write(to: testTempURL)
        try cacheMgr.cacheFile(fileId: testEvictId, from: testTempURL, policy: .automatic)
        assert(cacheMgr.isCached(fileId: testEvictId), "File cached successfully before eviction")
        
        SyncManager.shared.updateMetadata(FileMetadata(
            fileId: testEvictId,
            name: "test_evict.txt",
            parentId: "ROOT",
            isDirectory: false,
            syncStatus: .synced,
            size: 20
        ))
        assert(SyncManager.shared.getMetadata(fileId: testEvictId)?.syncStatus == .synced, "SyncStatus is synced before eviction")
        
        try cacheMgr.evictFile(fileId: testEvictId)
        assert(!cacheMgr.isCached(fileId: testEvictId), "File physical cache removed after evictFile")
        assert(SyncManager.shared.getMetadata(fileId: testEvictId)?.syncStatus == .cloudOnly, "File syncStatus marked as .cloudOnly after evictFile")
        try? FileManager.default.removeItem(at: testTempURL)
        
        // 14.3 Thumbnail timestamp invalidation
        let thumbMgr = ThumbnailManager.shared
        let keyWithoutTS = thumbMgr.cacheKey(fileId: "pic.jpg", size: CGSize(width: 256, height: 256), timestamp: nil)
        let keyWithTS = thumbMgr.cacheKey(fileId: "pic.jpg", size: CGSize(width: 256, height: 256), timestamp: 1710000000)
        assert(keyWithTS.contains("1710000000"), "Thumbnail cache key contains timestamp")
        assert(!keyWithoutTS.contains("1710000000"), "Thumbnail cache key without timestamp omits timestamp")
        
        // 14.4 Catalog merge & getEntry(forFileId:)
        let catA = ThumbnailCatalog()
        let catB = ThumbnailCatalog()
        let dataA = "DATA_A".data(using: .utf8)!
        let dataB = "DATA_B".data(using: .utf8)!
        catA.addOrUpdate(filename: "a.jpg", fileId: "id_a", imageData: dataA, timestamp: 100, width: 100, height: 100)
        catB.addOrUpdate(filename: "b.jpg", fileId: "id_b", imageData: dataB, timestamp: 200, width: 100, height: 100)
        
        catA.merge(with: catB)
        assert(catA.count == 2, "ThumbnailCatalog.merge merges entries from second catalog")
        assert(catA.getEntry(forFileId: "id_b")?.timestamp == 200, "ThumbnailCatalog.getEntry(forFileId:) finds merged entry")
        
        // 14.5 DirectoryThumbnailCatalogManager stale check
        let catalogManager = DirectoryThumbnailCatalogManager.shared
        let freshData = catalogManager.getThumbnailData(directoryId: "dir_test_123", fileId: "file_pdf_999", minTimestamp: 1600000000)
        assert(freshData != nil, "getThumbnailData with older minTimestamp returns thumbnail")
        let staleData = catalogManager.getThumbnailData(directoryId: "dir_test_123", fileId: "file_pdf_999", minTimestamp: 1800000000)
        assert(staleData == nil, "getThumbnailData with future minTimestamp returns nil (stale invalidated)")
        
        // 14.6 Streaming encryption roundtrip
        let encryption = VFSEncryption()
        let rawCleartextURL = FileManager.default.temporaryDirectory.appendingPathComponent("clear_\(UUID().uuidString).bin")
        let rawCiphertextURL = FileManager.default.temporaryDirectory.appendingPathComponent("cipher_\(UUID().uuidString).bin")
        let decryptedCleartextURL = FileManager.default.temporaryDirectory.appendingPathComponent("dec_\(UUID().uuidString).bin")
        let samplePayload = "STREAMING_CIPHER_TEST_PAYLOAD_12345".data(using: .utf8)!
        try samplePayload.write(to: rawCleartextURL)
        
        let testMasterkey = try Masterkey.createNew()
        try encryption.encryptFile(from: rawCleartextURL, to: rawCiphertextURL, key: testMasterkey)
        assert(FileManager.default.fileExists(atPath: rawCiphertextURL.path), "encryptFile creates ciphertext file")
        
        try encryption.decryptFile(from: rawCiphertextURL, to: decryptedCleartextURL, key: testMasterkey)
        assert(FileManager.default.fileExists(atPath: decryptedCleartextURL.path), "decryptFile creates decrypted cleartext file")
        let decryptedBytes = try Data(contentsOf: decryptedCleartextURL)
        assert(decryptedBytes == samplePayload, "decryptFile streaming decrypted bytes match original payload byte-for-byte")
        
        try? FileManager.default.removeItem(at: rawCleartextURL)
        try? FileManager.default.removeItem(at: rawCiphertextURL)
        try? FileManager.default.removeItem(at: decryptedCleartextURL)
        
        // 14.7 Pinned policy preservation on re-caching
        let pinTestId = "pinned_test_\(UUID().uuidString).txt"
        let pinTempURL = FileManager.default.temporaryDirectory.appendingPathComponent(pinTestId)
        try "PINNED_DATA".data(using: .utf8)!.write(to: pinTempURL)
        try cacheMgr.cacheFile(fileId: pinTestId, from: pinTempURL, policy: .pinned)
        assert(cacheMgr.getCacheMetadata(fileId: pinTestId)?.policy == .pinned, "File cached with .pinned policy")
        // Now simulate editing the file: call cacheFile with default .automatic policy
        try "PINNED_DATA_EDITED".data(using: .utf8)!.write(to: pinTempURL)
        try cacheMgr.cacheFile(fileId: pinTestId, from: pinTempURL, policy: .automatic)
        assert(cacheMgr.getCacheMetadata(fileId: pinTestId)?.policy == .pinned, "cacheFile preserves .pinned policy on modification")
        try? cacheMgr.removeCachedFile(fileId: pinTestId)
        try? FileManager.default.removeItem(at: pinTempURL)
        
        // 14.8 ThumbnailCatalog removal & compaction
        catA.remove(fileId: "id_a")
        assert(catA.count == 1, "ThumbnailCatalog.remove(fileId:) decreases count")
        assert(catA.getEntry(forFileId: "id_a") == nil, "Removed fileId no longer found in catalog")
        catA.compactIfNeeded()
        assert(catA.count == 1, "ThumbnailCatalog compaction preserves active entries")
        
        // 14.9 DirectoryThumbnailCatalogManager removal
        catalogManager.removeThumbnail(directoryId: "dir_test_123", fileId: "file_pdf_999")
        let removedData = catalogManager.getThumbnailData(directoryId: "dir_test_123", fileId: "file_pdf_999")
        assert(removedData == nil, "removeThumbnail successfully removes thumbnail entry from directory catalog")
        
        // 14.10 Direct data caching & pinFile/unpinFile toggling
        let directDataId = "direct_data_\(UUID().uuidString).bin"
        let sampleData = "SAMPLE_DIRECT_DATA".data(using: .utf8)!
        try cacheMgr.cacheFile(fileId: directDataId, data: sampleData)
        assert(cacheMgr.isCached(fileId: directDataId), "cacheFile(fileId:data:) writes file to disk")
        assert(cacheMgr.getCacheMetadata(fileId: directDataId)?.size == Int64(sampleData.count), "cacheFile(fileId:data:) records CacheMetadata with accurate size")
        
        cacheMgr.pinFile(fileId: directDataId)
        assert(cacheMgr.getCacheMetadata(fileId: directDataId)?.policy == .pinned, "pinFile sets policy to .pinned")
        cacheMgr.unpinFile(fileId: directDataId)
        assert(cacheMgr.getCacheMetadata(fileId: directDataId)?.policy == .automatic, "unpinFile restores policy to .automatic")
        try? cacheMgr.removeCachedFile(fileId: directDataId)
        
        // 14.11 Thumbnail invalidate prefix isolation
        let thumbAId = "photo_img"
        let thumbBId = "photo_img_extended"
        let thumbDataA = "THUMB_A".data(using: .utf8)!
        let thumbDataB = "THUMB_B".data(using: .utf8)!
        let thumbSize = CGSize(width: 256, height: 256)
        
        thumbMgr.saveThumbnailToCache(data: thumbDataA, fileId: thumbAId, size: thumbSize)
        thumbMgr.saveThumbnailToCache(data: thumbDataB, fileId: thumbBId, size: thumbSize)
        
        // Invalidate photo_img (must NOT delete photo_img_extended)
        thumbMgr.invalidate(fileId: thumbAId)
        // Wait briefly for barrier queue execution
        try await Task.sleep(nanoseconds: 80_000_000)
        
        assert(thumbMgr.getCachedThumbnailData(fileId: thumbAId, size: thumbSize) == nil, "Invalidated thumbnail is removed")
        assert(thumbMgr.getCachedThumbnailData(fileId: thumbBId, size: thumbSize) != nil, "Sibling thumbnail with shared prefix is safely preserved")
        
        thumbMgr.invalidate(fileId: thumbBId)
    }
    
    // Coverage consolidated from the former XCTest target.
    do {
        let testVaultId = "test_\(UUID().uuidString)"
        let db = VFSDatabase(vaultId: testVaultId)
        try db.initialize(vaultId: testVaultId, basePath: "/test")

        // Setup hierarchy:
        // rootDir
        // ├── subDir1
        // │   └── file1
        // └── subDir2
        //     ├── file2
        //     └── nestedDir
        //         └── file3
        try db.insertDirectory(id: "rootDir", name: "rootDir", parentId: "ROOT", encryptedId: "rootDir", remotePath: "/rootDir")
        try db.insertDirectory(id: "subDir1", name: "subDir1", parentId: "rootDir", encryptedId: "subDir1", remotePath: "/rootDir/subDir1")
        try db.insertDirectory(id: "subDir2", name: "subDir2", parentId: "rootDir", encryptedId: "subDir2", remotePath: "/rootDir/subDir2")
        try db.insertDirectory(id: "nestedDir", name: "nestedDir", parentId: "subDir2", encryptedId: "nestedDir", remotePath: "/rootDir/subDir2/nestedDir")

        try db.insertFile(id: "file1", name: "file1.txt", parentId: "subDir1", size: 100, encryptedName: "file1.txt", remotePath: "/rootDir/subDir1/file1.txt")
        try db.insertFile(id: "file2", name: "file2.txt", parentId: "subDir2", size: 200, encryptedName: "file2.txt", remotePath: "/rootDir/subDir2/file2.txt")
        try db.insertFile(id: "file3", name: "file3.txt", parentId: "nestedDir", size: 300, encryptedName: "file3.txt", remotePath: "/rootDir/subDir2/nestedDir/file3.txt")

        let subDir2Children = db.getAllDescendantFileIds(directoryId: "subDir2")
        assert(Set(subDir2Children) == Set(["file2", "file3"]), "testVFSDatabaseDescendantFileIds")

        let rootChildren = db.getAllDescendantFileIds(directoryId: "rootDir")
        assert(Set(rootChildren) == Set(["file1", "file2", "file3"]), "testVFSDatabaseDescendantFileIds")

        let emptyChildren = db.getAllDescendantFileIds(directoryId: "nonExistent")
        assert(emptyChildren.isEmpty, "testVFSDatabaseDescendantFileIds")
    } catch {
        assert(false, "testVFSDatabaseDescendantFileIds: \(error)")
    }

    do {
        let op = SyncOperation.move(itemId: "item123", sourceRemotePath: "/old/path.txt", targetRemotePath: "/new/path.txt")
        assert(op.fileId == "item123", "testSyncOperationMoveCodable")
        assert(op.description == "Move", "testSyncOperationMoveCodable")

        let data = try JSONEncoder().encode(op)
        let decoded = try JSONDecoder().decode(SyncOperation.self, from: data)
        if case .move(let id, let src, let dst) = decoded {
            assert(id == "item123", "testSyncOperationMoveCodable")
            assert(src == "/old/path.txt", "testSyncOperationMoveCodable")
            assert(dst == "/new/path.txt", "testSyncOperationMoveCodable")
        } else {
            assert(false, "Decoded operation mismatch")
        }
    } catch {
        assert(false, "testSyncOperationMoveCodable: \(error)")
    }

    do {
        let sync = SyncManager.shared
        let oldId = "pending_\(UUID().uuidString)"
        let newId = "file_\(UUID().uuidString)"

        sync.addToSyncQueue(.upload(fileId: oldId, localPath: "/tmp/local", remotePath: "/old/remote"))
        assert(sync.hasPendingUpload(fileId: oldId), "testUpdatePendingOperationInSyncManager")

        sync.updatePendingOperation(oldFileId: oldId, newFileId: newId, newRemotePath: "/new/remote", newName: "new.txt", newParentId: "parentB")
        assert(sync.hasPendingUpload(fileId: newId), "testUpdatePendingOperationInSyncManager")
    } catch {
        assert(false, "testUpdatePendingOperationInSyncManager: \(error)")
    }

    print("\n========================================")
    print("🏁 Test Results: \(passed) passed, \(failed) failed")
    print("========================================")
    
    if failed > 0 {
        exit(1)
    }
}

Task {
    do {
        if CommandLine.arguments.contains("--copy-only") {
            try await runVFSCopyMovePerformanceRegressionTests()
            exit(0)
        }
        if CommandLine.arguments.contains("--baidupan-only") {
            try await runBaiduPanRegressions()
            exit(0)
        }
        if CommandLine.arguments.contains("--file-provider-state-only") {
            try runContentRevisionRegressionTests()
            try runFileProviderPresentationRegressionTests()
            try runSyncStateLifecycleRegressionTests()
            print("✅ All File Provider state regressions passed")
            exit(0)
        }
        if CommandLine.arguments.contains("--webdav-only") || CommandLine.arguments.contains("--regression-only") {
            try await runStorageAvailabilityRegressionTests()
            try runSQLiteTransactionRegressionTests()
            try runContentRevisionRegressionTests()
            try runFileProviderPresentationRegressionTests()
            try await runDatabaseSecurityRegressionTests()
            try await runWebDAVRegressionTests()
            try await runWebDAVBoundaryRegressionTests()
            try await runSyncRegressionTests()
            try await runSyncSafetyRegressionTests()
            try runSyncCommitJournalRegressionTests()
            try runSyncSaveAcceptanceRegressionTests()
            try runSyncStateLifecycleRegressionTests()
            try await runUploadVerificationRegressionTests()
            try await runWebDAVUploadProofRegressionTests()
            try await runVFSMutationRevisionRegressionTests()
            try await runDirectoryDeleteRegressionTests()
            try await runVFSCopyMovePerformanceRegressionTests()
            try runDeletedPayloadRecoveryRegressionTests()
            try await runDirectoryReconciliationRegressionTests()
            try runQueueSchedulingRegressionTests()
            try await runQueueVersionPerformanceRegressionTests()
            try await runCacheRegressionTests()
            try runCacheIntegrityRegressionTests()
            try await runDataSafetyRegressionTests()
            try await runCryptomatorRandomAccessRegressionTests()
            try await runItemAliasStoreRegressionTests()
            try await runFileOpenSyncStatusRegressionTests()
            try await runVaultLockUnlockRegressionTests()
            try await runExcludeSyncRegressionTests()
            try await runProgressPublisherRegressionTests()
            try await runBaiduPanRegressions()
            print("✅ All storage & reliability regressions passed")
            exit(0)
        }
        
        if !CommandLine.arguments.contains("--regression-only") { try await runTests() }
        try await runStorageAvailabilityRegressionTests()
        try runSQLiteTransactionRegressionTests()
        try runContentRevisionRegressionTests()
        try runFileProviderPresentationRegressionTests()
        try await runBaiduPanRegressions()
        try await runDatabaseSecurityRegressionTests()
        try await runWebDAVRegressionTests()
        try await runWebDAVBoundaryRegressionTests()
        try await runSyncRegressionTests()
        try await runSyncSafetyRegressionTests()
        try runSyncCommitJournalRegressionTests()
        try runSyncSaveAcceptanceRegressionTests()
        try runSyncStateLifecycleRegressionTests()
        try await runUploadVerificationRegressionTests()
        try await runWebDAVUploadProofRegressionTests()
        try await runVFSMutationRevisionRegressionTests()
        try await runDirectoryDeleteRegressionTests()
        try await runVFSCopyMovePerformanceRegressionTests()
        try runDeletedPayloadRecoveryRegressionTests()
        try await runDirectoryReconciliationRegressionTests()
        try runQueueSchedulingRegressionTests()
        try await runQueueVersionPerformanceRegressionTests()
        try await runCacheRegressionTests()
        try runCacheIntegrityRegressionTests()
        try await runDataSafetyRegressionTests()
        try await runCryptomatorRandomAccessRegressionTests()
        try await runItemAliasStoreRegressionTests()
        try await runFileOpenSyncStatusRegressionTests()
        try await runVaultLockUnlockRegressionTests()
        try await runExcludeSyncRegressionTests()
        try await runProgressPublisherRegressionTests()
        try await runBaiduPanRegressions()
        print("✅ All reliability regressions passed")
        exit(0)
    } catch {
        print("Fatal test runner error: \(error)")
        exit(1)
    }
}

RunLoop.main.run()
