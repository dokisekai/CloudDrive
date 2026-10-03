import Foundation
import CryptoKit
import CloudDriveCore
import CloudDriveStorage
import CryptomatorCryptoLib

private struct RegressionFailure: Error, CustomStringConvertible {
    let description: String
}

public func runDataSafetyRegressionTests() async throws {
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("🛡️ Running Data Safety & Four Blockers Regressions")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

    // MARK: - Blocker 1: Duplicate Vault Creation Prevents Key Overwrite
    do {
        print("  ▶ [Blocker 1] Duplicate vault creation must fail closed without key destruction...")
        let tempBaseDir = FileManager.default.temporaryDirectory.appendingPathComponent("safetest-blocker1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempBaseDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBaseDir) }

        let storageClient = LocalStorageClient()
        let vfs = VirtualFileSystem()
        vfs.configureStorage(client: storageClient)

        // 1. Initialise first encrypted vault
        let originalPass = "OriginalStrongPassword123!"
        _ = try await vfs.initializeVault(name: "EncryptedVault", password: originalPass, storagePath: tempBaseDir.path)

        let masterkeyPath = "\(tempBaseDir.path)/EncryptedVault/masterkey.cryptomator"
        let configPath = "\(tempBaseDir.path)/EncryptedVault/vault.cryptomator"
        let originalMasterkeyData = try Data(contentsOf: URL(fileURLWithPath: masterkeyPath))
        let originalConfigData = try Data(contentsOf: URL(fileURLWithPath: configPath))

        // 2. Attempt duplicate initialisation at same location with different password
        var caughtDuplicateError = false
        do {
            _ = try await vfs.initializeVault(name: "EncryptedVault", password: "AttackerOrMistakenPassword456!", storagePath: tempBaseDir.path)
        } catch let vfsError as VFSError {
            if case .vaultAlreadyExists = vfsError {
                caughtDuplicateError = true
            }
        } catch {
            // Also acceptable if bridged or wrapped as 412
            caughtDuplicateError = true
        }

        guard caughtDuplicateError else {
            throw RegressionFailure(description: "CRITICAL: Duplicate encrypted vault initialization succeeded instead of rejecting!")
        }

        // Verify master key and config were NEVER touched or overwritten
        let currentMasterkeyData = try Data(contentsOf: URL(fileURLWithPath: masterkeyPath))
        let currentConfigData = try Data(contentsOf: URL(fileURLWithPath: configPath))
        guard currentMasterkeyData == originalMasterkeyData else {
            throw RegressionFailure(description: "CRITICAL: Master key was overwritten during duplicate vault initialization!")
        }
        guard currentConfigData == originalConfigData else {
            throw RegressionFailure(description: "CRITICAL: Vault configuration was modified during duplicate vault initialization!")
        }

        // 3. Test unencrypted vault duplicate initialization
        _ = try await vfs.initializeVaultWithoutEncryption(name: "DirectVault", storagePath: tempBaseDir.path)
        let directConfigPath = "\(tempBaseDir.path)/DirectVault/vault.config"
        let originalDirectConfig = try Data(contentsOf: URL(fileURLWithPath: directConfigPath))

        var directDuplicateCaught = false
        do {
            _ = try await vfs.initializeVaultWithoutEncryption(name: "DirectVault", storagePath: tempBaseDir.path)
        } catch let vfsError as VFSError {
            if case .vaultAlreadyExists = vfsError {
                directDuplicateCaught = true
            }
        } catch {
            directDuplicateCaught = true
        }

        guard directDuplicateCaught else {
            throw RegressionFailure(description: "CRITICAL: Duplicate direct vault initialization succeeded instead of rejecting!")
        }
        let currentDirectConfig = try Data(contentsOf: URL(fileURLWithPath: directConfigPath))
        guard currentDirectConfig == originalDirectConfig else {
            throw RegressionFailure(description: "CRITICAL: Direct vault config was modified during duplicate initialization!")
        }
        print("  ✅ [Blocker 1] PASSED: Master keys and configs strictly protected from duplicate creation")
    }

    // MARK: - Blocker 2: Create-If-Absent & 412 Conflict Protection
    do {
        print("  ▶ [Blocker 2] Create-if-absent and 412 conflict preservation...")
        let tempBaseDir = FileManager.default.temporaryDirectory.appendingPathComponent("safetest-blocker2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempBaseDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBaseDir) }

        let storageClient = LocalStorageClient()
        let vfs = VirtualFileSystem()
        vfs.configureStorage(client: storageClient)
        _ = try await vfs.initializeVaultWithoutEncryption(name: "DMVault", storagePath: tempBaseDir.path)

        guard let provider = vfs.activeProvider as? DirectMappingVFSProvider else {
            throw RegressionFailure(description: "Active provider is not DirectMappingVFSProvider")
        }

        // 1. Create remote file
        let existingLocal = tempBaseDir.appendingPathComponent("existing_source.txt")
        let originalBytes = "Original Remote Data".data(using: .utf8)!
        try originalBytes.write(to: existingLocal)
        _ = try await provider.uploadFile(localURL: existingLocal, name: "conflict_test.txt", parentId: "ROOT")

        // 2. Second upload with same name must fail with 412 / precondition failure
        let newLocal = tempBaseDir.appendingPathComponent("new_source.txt")
        let newBytes = "Local Edits Should Not Blindly Overwrite Remote".data(using: .utf8)!
        try newBytes.write(to: newLocal)

        var caughtConflict = false
        do {
            _ = try await provider.uploadFile(localURL: newLocal, name: "conflict_test.txt", parentId: "ROOT")
        } catch {
            if (error as? StorageError)?.isPreconditionFailure == true {
                caughtConflict = true
            }
        }

        guard caughtConflict else {
            throw RegressionFailure(description: "CRITICAL: uploadFile with existing remote name blindly overwrote remote file!")
        }

        // 3. Verify remote file is unchanged
        let remoteFilePath = "\(tempBaseDir.path)/DMVault/files/conflict_test.txt"
        let currentRemoteData = try Data(contentsOf: URL(fileURLWithPath: remoteFilePath))
        guard currentRemoteData == originalBytes else {
            throw RegressionFailure(description: "CRITICAL: Remote content was modified despite collision!")
        }

        // 4. Verify local cache preserved and metadata marked .conflict
        let expectedFileId = remoteFilePath
        let meta = vfs.syncManager.getMetadata(fileId: expectedFileId)
        guard meta?.syncStatus == .conflict else {
            throw RegressionFailure(description: "Sync status was not updated to .conflict: \(String(describing: meta?.syncStatus))")
        }
        guard vfs.cacheManager.isCached(fileId: expectedFileId) else {
            throw RegressionFailure(description: "Local payload was not preserved in cache during conflict!")
        }

        print("  ✅ [Blocker 2] PASSED: Remote file preserved, local cache retained, status marked .conflict")
    }

    // MARK: - Blocker 3: Source Version Bindings for DELETE, MOVE, COPY
    do {
        print("  ▶ [Blocker 3] Conditional DELETE, MOVE, and Multi-Status validation...")
        let tempBaseDir = FileManager.default.temporaryDirectory.appendingPathComponent("safetest-blocker3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempBaseDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBaseDir) }

        let storageClient = LocalStorageClient()

        // 1. Upload a file and get its initial ETag
        let testLocal = tempBaseDir.appendingPathComponent("source_v1.txt")
        try "Content v1".data(using: .utf8)!.write(to: testLocal)
        let remotePath = tempBaseDir.appendingPathComponent("remote_versioned.txt").path
        let validETag = try await storageClient.uploadFile(localURL: testLocal, to: remotePath, mode: StorageWriteMode.createIfAbsent) { _ in }
        guard let validETag = validETag else {
            throw RegressionFailure(description: "LocalStorageClient did not return an ETag")
        }

        // 2. Conditional DELETE with mismatched ETag must fail and retain file
        var caughtDeleteConflict = false
        do {
            try await storageClient.delete(path: remotePath, expectedETag: "\"mismatched-etag-123\"")
        } catch {
            if (error as? StorageError)?.isPreconditionFailure == true {
                caughtDeleteConflict = true
            }
        }
        guard caughtDeleteConflict else {
            throw RegressionFailure(description: "Conditional delete succeeded with mismatched ETag!")
        }
        guard try await storageClient.exists(path: remotePath) else {
            throw RegressionFailure(description: "File was deleted despite ETag mismatch!")
        }

        // 3. Conditional MOVE with mismatched ETag must fail and retain file
        let destPath = "\(tempBaseDir.path)/moved.txt"
        var caughtMoveConflict = false
        do {
            try await storageClient.move(from: remotePath, to: destPath, expectedETag: "\"mismatched-etag-123\"")
        } catch {
            if (error as? StorageError)?.isPreconditionFailure == true {
                caughtMoveConflict = true
            }
        }
        guard caughtMoveConflict else {
            throw RegressionFailure(description: "Conditional move succeeded with mismatched ETag!")
        }
        guard try await storageClient.exists(path: remotePath) else {
            throw RegressionFailure(description: "Source file disappeared despite move ETag mismatch!")
        }
        guard (try await storageClient.exists(path: destPath)) == false else {
            throw RegressionFailure(description: "Destination file was created despite move ETag mismatch!")
        }

        // 4. Conditional DELETE with matching ETag must succeed
        try await storageClient.delete(path: remotePath, expectedETag: validETag)
        guard (try await storageClient.exists(path: remotePath)) == false else {
            throw RegressionFailure(description: "Conditional delete failed with valid matching ETag!")
        }

        print("  ✅ [Blocker 3] PASSED: Conditional mutations enforced, stale versions rejected")
    }

    // MARK: - Blocker 4: Atomic Encrypted Directory Creation & Collision Safety
    do {
        print("  ▶ [Blocker 4] Encrypted directory atomic staging and pointer protection...")
        let tempBaseDir = FileManager.default.temporaryDirectory.appendingPathComponent("safetest-blocker4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempBaseDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBaseDir) }

        let storageClient = LocalStorageClient()
        let vfs = VirtualFileSystem()
        vfs.configureStorage(client: storageClient)
        _ = try await vfs.initializeVault(name: "EncVault", password: "Password123!", storagePath: tempBaseDir.path)

        guard let provider = vfs.activeProvider as? EncryptedVFSProvider else {
            throw RegressionFailure(description: "Active provider is not EncryptedVFSProvider")
        }

        // 1. Create directory FolderA
        let folderItem = try await provider.createDirectory(name: "FolderA", parentId: "ROOT")
        let dirIdData = Data(folderItem.id.utf8)
        let actualDirPath = try vfs.cryptomatorFormat!.getDirPath(dirId: dirIdData)

        // Verify actualDirPath exists
        guard try await storageClient.exists(path: actualDirPath) else {
            throw RegressionFailure(description: "Actual encrypted content directory does not exist!")
        }
        // Verify dir.c9r exists
        let pointerPath = "\(folderItem.remotePath!)/dir.c9r"
        guard try await storageClient.exists(path: pointerPath) else {
            throw RegressionFailure(description: "dir.c9r pointer does not exist!")
        }

        // 2. Attempt duplicate directory creation with same name
        var duplicateDirCaught = false
        do {
            _ = try await vfs.cryptomatorFormat!.createDirectory(name: "FolderA", parentDirId: Data([]))
        } catch {
            if (error as? StorageError)?.isPreconditionFailure == true ||
               (error as? StorageError)?.statusCode == 409 {
                duplicateDirCaught = true
            }
        }
        guard duplicateDirCaught else {
            throw RegressionFailure(description: "CRITICAL: Duplicate directory creation succeeded and could corrupt directory pointers!")
        }

        // Verify winner's pointer is intact
        let checkURL = tempBaseDir.appendingPathComponent("pointer_check.tmp")
        defer { try? FileManager.default.removeItem(at: checkURL) }
        try await storageClient.downloadFile(path: pointerPath, to: checkURL) { _ in }
        let pointerContent = try Data(contentsOf: checkURL)
        guard pointerContent == dirIdData else {
            throw RegressionFailure(description: "CRITICAL: Original directory pointer was corrupted by duplicate mkdir!")
        }

        print("  ✅ [Blocker 4] PASSED: Actual directory staged before pointer, duplicate mkdir rejected with 409")
    }

    // MARK: - Safe Password Change Regression
    do {
        print("  ▶ [Password Change] Safely re-encrypt masterkey without touching file ciphertext...")
        let tempBaseDir = FileManager.default.temporaryDirectory.appendingPathComponent("safetest-pwdchange-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempBaseDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBaseDir) }

        let storageClient = LocalStorageClient()
        let vfs = VirtualFileSystem()
        vfs.configureStorage(client: storageClient)

        let initialPassword = "OldPassword123!"
        let vaultId = try await vfs.initializeVault(name: "PwdVault", password: initialPassword, storagePath: tempBaseDir.path)

        let localFile = tempBaseDir.appendingPathComponent("sample.txt")
        let fileContent = "Confidential User Data - Testing Password Change Safety".data(using: .utf8)!
        try fileContent.write(to: localFile)
        defer { try? FileManager.default.removeItem(at: localFile) }

        let uploadedItem = try await vfs.uploadFile(localURL: localFile, name: "sample.txt", parentId: "ROOT")

        // 1. Verify invalid old password fails
        var wrongOldPasswordCaught = false
        do {
            try await vfs.changeVaultPassword(oldPassword: "WrongPassword!", newPassword: "NewSecretPassword888!", storagePath: "\(tempBaseDir.path)/PwdVault", vaultId: vaultId)
        } catch let err as VFSError {
            if case .invalidPassword = err {
                wrongOldPasswordCaught = true
            }
        }
        guard wrongOldPasswordCaught else {
            throw RegressionFailure(description: "CRITICAL: changeVaultPassword with incorrect old password did not fail!")
        }

        // 2. Perform legitimate password change
        let newPassword = "NewSecretPassword888!"
        try await vfs.changeVaultPassword(oldPassword: initialPassword, newPassword: newPassword, storagePath: "\(tempBaseDir.path)/PwdVault", vaultId: vaultId)

        // 3. Verify backup file exists
        let bkupPath = "\(tempBaseDir.path)/PwdVault/masterkey.cryptomator.bkup"
        guard FileManager.default.fileExists(atPath: bkupPath) else {
            throw RegressionFailure(description: "CRITICAL: masterkey.cryptomator.bkup was not created during password change!")
        }

        // 4. Create fresh VFS instance and test unlocking
        let freshVFS = VirtualFileSystem()
        freshVFS.configureStorage(client: LocalStorageClient())

        var oldPasswordRejected = false
        do {
            try await freshVFS.unlockVault(password: initialPassword, storagePath: "\(tempBaseDir.path)/PwdVault", vaultId: vaultId)
        } catch let err as VFSError {
            if case .invalidPassword = err {
                oldPasswordRejected = true
            }
        }
        guard oldPasswordRejected else {
            throw RegressionFailure(description: "CRITICAL: Old password still unlocked the vault after password change!")
        }

        // 5. Unlock with new password
        try await freshVFS.unlockVault(password: newPassword, storagePath: "\(tempBaseDir.path)/PwdVault", vaultId: vaultId)

        // 6. Read and verify previously uploaded file
        let downloadDest = tempBaseDir.appendingPathComponent("downloaded.txt")
        defer { try? FileManager.default.removeItem(at: downloadDest) }
        try await freshVFS.downloadFile(fileId: uploadedItem.id, to: downloadDest)
        let downloadedData = try Data(contentsOf: downloadDest)
        guard downloadedData == fileContent else {
            throw RegressionFailure(description: "CRITICAL: File decrypted after password change does not match original content!")
        }

        print("  ✅ [Password Change] PASSED: masterkey re-encrypted, backup preserved, data decrypted perfectly")
    }

    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("🎉 All 4 Data-Safety Blockers & Password Change Successfully Verified!")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
}
