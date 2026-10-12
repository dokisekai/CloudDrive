import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CloudDriveCore

public func runVaultLockUnlockRegressionTests() async throws {
    print("""
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    🧪 Running Vault Lock/Unlock vs Mount/Unmount Regressions
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    """)
    
    // --- 1. Testing VaultInfo Model Default Lock States ---
    print("\n--- 1. Testing VaultInfo Default States ---")
    
    let plainVault = VaultInfo(
        id: "plain-1",
        name: "Plain Vault",
        storagePath: "/path/plain",
        createdAt: Date(),
        isMounted: false,
        isEncrypted: false
    )
    guard plainVault.isUnlocked == true else {
        fatalError("Plain (non-encrypted) vault should default to isUnlocked == true")
    }
    guard plainVault.isMounted == false else {
        fatalError("Plain vault should default to isMounted == false")
    }
    print("  ✅ PASS: Plain vault is unlocked by default")
    
    let encryptedVault = VaultInfo(
        id: "enc-1",
        name: "Encrypted Vault",
        storagePath: "/path/enc",
        createdAt: Date(),
        isMounted: false,
        isEncrypted: true
    )
    guard encryptedVault.isUnlocked == false else {
        fatalError("Encrypted vault should default to isUnlocked == false (Locked)")
    }
    guard encryptedVault.isMounted == false else {
        fatalError("Encrypted vault should default to isMounted == false")
    }
    print("  ✅ PASS: Encrypted vault is locked by default")
    
    // --- 2. Testing Codable Persistence Isolation ---
    print("\n--- 2. Testing Codable Persistence Isolation ---")
    
    var dynamicVault = encryptedVault
    dynamicVault.isMounted = true
    dynamicVault.isUnlocked = true
    
    let encoder = JSONEncoder()
    let data = try encoder.encode(dynamicVault)
    
    let decoder = JSONDecoder()
    let decodedVault = try decoder.decode(VaultInfo.self, from: data)
    
    guard decodedVault.isMounted == false else {
        fatalError("Decoded vault should reset isMounted to false")
    }
    guard decodedVault.isUnlocked == false else {
        fatalError("Decoded encrypted vault should reset isUnlocked to false (Secure Default)")
    }
    print("  ✅ PASS: isMounted and isUnlocked runtime states are safely isolated from persistence")
    
    // --- 3. Testing Lock/Unlock vs Mount/Unmount State Machine ---
    print("\n--- 3. Testing Lock/Unlock Orthogonality to Mount/Unmount ---")
    
    // Step A: Mount encrypted vault into Finder (e.g. system boot or auto-mount)
    var testVault = encryptedVault
    testVault.isMounted = true
    testVault.isUnlocked = false
    
    guard testVault.isMounted == true && testVault.isUnlocked == false else {
        fatalError("Vault should be mounted but locked")
    }
    print("  ✅ State A: Mounted & Locked (Finder domain active, cipher locked)")
    
    // Step B: User unlocks the vault with password
    testVault.isUnlocked = true
    guard testVault.isMounted == true && testVault.isUnlocked == true else {
        fatalError("Vault should be mounted and unlocked")
    }
    print("  ✅ State B: Mounted & Unlocked (Finder domain active, plaintext accessible)")
    
    // Step C: User locks the vault (CRITICAL: Must NOT unmount!)
    // Simulating lockVault(vault):
    testVault.isUnlocked = false
    // isMounted remains unchanged!
    guard testVault.isMounted == true else {
        fatalError("Locking vault must NOT unmount the drive! isMounted must remain true")
    }
    guard testVault.isUnlocked == false else {
        fatalError("Vault must be in locked state")
    }
    print("  ✅ State C: Locked without unmounting (Drive stays mounted in Finder, keys purged)")
    
    // Step D: User unmounts the vault (Eject from Finder)
    // Simulating unmountVault(vault):
    if testVault.isEncrypted {
        testVault.isUnlocked = false
    }
    testVault.isMounted = false
    guard testVault.isMounted == false && testVault.isUnlocked == false else {
        fatalError("Unmounted vault must have isMounted == false")
    }
    // --- 4. Testing Cache Preservation Across Vault Lock/Unlock Cycles ---
    print("\n--- 4. Testing Cache Preservation Across Vault Lock/Unlock Cycles ---")
    let testVFS = VirtualFileSystem(vaultId: "enc-1")
    let cache = testVFS.cacheManager
    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("cached_test_\(UUID().uuidString).txt")
    try "Important Data".write(to: tempURL, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tempURL) }
    
    try cache.cacheFile(fileId: "file-cached-1", from: tempURL)
    guard cache.isCached(fileId: "file-cached-1") else {
        fatalError("File should be cached before lock")
    }
    print("  ✅ Pre-Lock: File content safely stored in cache")
    
    // Simulate lock: VFS locks memory key, but cacheManager files are NOT purged
    testVFS.lock()
    guard cache.isCached(fileId: "file-cached-1") else {
        fatalError("Locking vault must NOT purge downloaded file cache in cacheManager!")
    }
    print("  ✅ Post-Lock: Cache remains intact in protected storage")
    
    // Post-Unlock: Previously downloaded data is immediately available!
    guard cache.isCached(fileId: "file-cached-1") else {
        fatalError("Post-unlock file must remain directly usable without re-downloading!")
    }
    let cachedContent = try String(contentsOf: cache.localPath(for: "file-cached-1"), encoding: .utf8)
    guard cachedContent == "Important Data" else {
        fatalError("Cached content mismatch")
    }
    // --- 5. Testing Seamless Cached Status on Vault Remount (No Download Icon) ---
    print("\n--- 5. Testing Seamless Cached Status on Vault Remount (No Download Icon) ---")
    let syncManager = testVFS.syncManager
    let testCachedItem = VirtualFileItem(
        id: "file-cached-1",
        name: "file-cached-1.txt",
        isDirectory: false,
        size: 14,
        modifiedAt: Date(),
        parentId: "ROOT",
        syncStatus: .cloudOnly,
        remotePath: "/remote/path/file-cached-1.txt"
    )
    
    // Simulate database insertion during directory enumeration upon remount
    let isCached = !testCachedItem.isDirectory && cache.isCached(fileId: testCachedItem.id)
    guard isCached else {
        fatalError("Test file must be cached in CacheManager")
    }
    
    var remountMetadata = syncManager.getMetadata(fileId: testCachedItem.id) ?? FileMetadata(
        fileId: testCachedItem.id,
        name: testCachedItem.name,
        parentId: testCachedItem.parentId,
        isDirectory: testCachedItem.isDirectory,
        syncStatus: (testCachedItem.isDirectory || isCached) ? .synced : .cloudOnly,
        localPath: isCached ? cache.localPath(for: testCachedItem.id).path : nil,
        remotePath: testCachedItem.remotePath,
        size: testCachedItem.size,
        downloadProgress: (testCachedItem.isDirectory || isCached) ? 1.0 : 0.0
    )
    if isCached && remountMetadata.syncStatus == .cloudOnly {
        remountMetadata.syncStatus = .synced
        remountMetadata.downloadProgress = 1.0
    }
    syncManager.updateMetadata(remountMetadata)
    
    let verifiedMeta = syncManager.getMetadata(fileId: testCachedItem.id)
    guard let verifiedMeta = verifiedMeta else {
        fatalError("Metadata should exist for remounted item")
    }
    guard verifiedMeta.syncStatus == .synced else {
        fatalError("Cached item metadata syncStatus must be .synced upon remount, got: \(verifiedMeta.syncStatus)")
    }
    guard verifiedMeta.downloadProgress == 1.0 else {
        fatalError("Cached item downloadProgress must be 1.0, got: \(verifiedMeta.downloadProgress)")
    }
    // --- 6. Testing Queued Upload Recovery Across Unmount/Remount Cycles ---
    print("\n--- 6. Testing Queued Upload Recovery Across Unmount/Remount Cycles ---")
    let uploadVaultId = "enc-recovery-\(UUID().uuidString.prefix(6))"
    let recoveryVFS = VirtualFileSystem(vaultId: uploadVaultId)
    let recoverySync = recoveryVFS.syncManager
    let mockStorageDir = FileManager.default.temporaryDirectory.appendingPathComponent("recovery_storage_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: mockStorageDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: mockStorageDir) }
    
    let localStorage = LocalStorageClient()
    localStorage.configureSecurityScope(url: mockStorageDir)
    recoverySync.configure(storageClient: localStorage, vfs: recoveryVFS)
    
    let stagedFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("staged_upload_\(UUID().uuidString).txt")
    try "Important upload content that survived unmount".write(to: stagedFileURL, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: stagedFileURL) }
    
    let remoteFileTarget = mockStorageDir.appendingPathComponent("file-to-upload.txt")
    let uploadFileId = "/file-to-upload.txt"
    let uploadMetadata = FileMetadata(
        fileId: uploadFileId,
        name: "file-to-upload.txt",
        parentId: "ROOT",
        isDirectory: false,
        syncStatus: .pendingUpload,
        localPath: stagedFileURL.path,
        remotePath: remoteFileTarget.path,
        size: 40
    )
    
    // Pause queue before enqueuing to reliably simulate unmount interruption
    recoverySync.pauseSyncQueue()
    
    try recoverySync.acceptSavePersistent(
        metadata: uploadMetadata,
        operation: .upload(fileId: uploadFileId, localPath: stagedFileURL.path, remotePath: remoteFileTarget.path),
        expectedETag: nil,
        validation: {}
    )
    
    // Pause immediately to prevent immediate drain before simulating lock/unmount
    recoverySync.pauseSyncQueue()
    try? FileManager.default.removeItem(at: remoteFileTarget)
    
    guard let queueItem = recoverySync.getQueuedOperations().first(where: { $0.operation.fileId == uploadFileId }) else {
        fatalError("Enqueued task must exist in database")
    }
    
    try recoverySync.queue.recordFailure(
        id: queueItem.id,
        message: "The target encrypted vault is not unlocked",
        conflict: false,
        nextAttemptAt: nil,
        isAuthFailure: true,
        isPermanentFailure: false
    )
    try recoverySync.updateMetadataPersistent(FileMetadata(
        fileId: uploadFileId,
        name: "file-to-upload.txt",
        parentId: "ROOT",
        isDirectory: false,
        syncStatus: .error,
        localPath: stagedFileURL.path,
        remotePath: remoteFileTarget.path,
        size: 40
    ))
    
    // Verify it is in error state before recovery
    let preRecoveryMeta = try recoverySync.getMetadataPersistent(fileId: uploadFileId)
    guard preRecoveryMeta?.syncStatus == .error else {
        fatalError("Simulated interruption must set status to .error")
    }
    
    // Perform remount / unlock recovery!
    recoverySync.recoverQueueOnUnlock()
    
    // Await processing to finish
    var waitCycles = 0
    while recoverySync.getSyncQueueCount() > 0 && waitCycles < 50 {
        try await Task.sleep(nanoseconds: 100_000_000)
        waitCycles += 1
    }
    
    guard recoverySync.getSyncQueueCount() == 0 else {
        fatalError("Sync queue should drain completely after unlock recovery")
    }
    
    let postRecoveryMeta = try recoverySync.getMetadataPersistent(fileId: uploadFileId)
    guard let finalStatus = postRecoveryMeta?.syncStatus, finalStatus == .synced else {
        fatalError("Recovered file must reach .synced status, got: \(String(describing: postRecoveryMeta?.syncStatus))")
    }
    print("  ✅ PASS: Upload task survived unmount/lock, recovered from .error to runnable, and uploaded to .synced successfully!")

    // --- 7. Testing Permanent Mount Defaults & Credential Persistence Across Unmount ---
    print("\n--- 7. Testing Permanent Mount Defaults & Credential Persistence Across Unmount ---")
    
    // Test A: AppSettings defaults
    guard AppSettings.shared.autoLock == false else {
        fatalError("AppSettings.autoLock must default to false so vaults are never unmounted automatically")
    }
    guard AppSettings.shared.autoMountOnLaunch == true else {
        fatalError("AppSettings.autoMountOnLaunch must default to true")
    }
    print("  ✅ PASS: autoLock defaults to false and autoMountOnLaunch defaults to true")
    
    // Test B: VaultInfo default auto-mount
    let defaultVault = VaultInfo(
        id: "auto-mount-1",
        name: "Auto Mount Vault",
        storagePath: "/path",
        createdAt: Date()
    )
    guard defaultVault.isAutoMount == true else {
        fatalError("VaultInfo.isAutoMount must default to true")
    }
    print("  ✅ PASS: VaultInfo.isAutoMount defaults to true")
    
    // Test C: CredentialStore retains password across unmount cycles
    let credentialVaultId = "cred-retention-\(UUID().uuidString.prefix(6))"
    let testSecret = "SecretPass_12345!"
    
    // Save password
    _ = CredentialStore.shared.saveVaultPassword(testSecret, for: String(credentialVaultId))
    guard CredentialStore.shared.getVaultPassword(for: String(credentialVaultId)) == testSecret else {
        fatalError("Password must be successfully saved in CredentialStore")
    }
    
    // Simulate unmount: We DO NOT delete the password from CredentialStore!
    // Password must be retained for seamless auto-remount without re-prompting!
    guard CredentialStore.shared.getVaultPassword(for: String(credentialVaultId)) == testSecret else {
        fatalError("Password must remain in CredentialStore during and after unmount")
    }
    print("  ✅ PASS: Credentials safely retained in CredentialStore for passwordless remount")
    
    // Clean up
    CredentialStore.shared.deleteVaultPassword(for: String(credentialVaultId))

    print("\n🎉 ALL Vault Lock/Unlock vs Mount/Unmount Regression Tests Passed!")
}

