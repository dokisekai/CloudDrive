import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CloudDriveSync
import CloudDriveVFS
import CloudDriveCore

public func runExcludeSyncRegressionTests() async throws {
    print("""
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    🧪 Running Exclude From Sync (.nosync) & Custom Actions Regressions
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    """)
    
    // --- 1. Builtin .nosync rules in IgnoreRuleEngine ---
    print("\n--- 1. Testing IgnoreRuleEngine Builtin .nosync Rules ---")
    let builtinRules = IgnoreRuleEngine.builtinRules
    assert(builtinRules.contains { $0.pattern == "*.nosync" }, "Builtin rules must contain *.nosync")
    assert(builtinRules.contains { $0.pattern == "*.nosync/" }, "Builtin rules must contain *.nosync/")
    assert(builtinRules.contains { $0.pattern == ".nosync" }, "Builtin rules must contain .nosync")
    print("  ✅ PASS: Builtin rules contain *.nosync, *.nosync/, .nosync")
    
    // --- 2. IgnoreRuleEngine matching for .nosync ---
    print("\n--- 2. Testing IgnoreRuleEngine shouldIgnore Matching ---")
    let engine = IgnoreRuleEngine.shared
    let testVaultId = "test_vault_nosync_\(UUID().uuidString)"
    
    assert(engine.shouldIgnore(path: "notes.txt.nosync", name: "notes.txt.nosync", isDirectory: false, vaultId: testVaultId), "notes.txt.nosync should be ignored by builtin rule")
    assert(engine.shouldIgnore(path: "Folder.nosync", name: "Folder.nosync", isDirectory: true, vaultId: testVaultId), "Folder.nosync should be ignored by builtin rule")
    assert(engine.shouldIgnore(path: "Folder.nosync/child.txt", name: "child.txt", isDirectory: false, vaultId: testVaultId), "Items inside .nosync directory should be ignored")
    assert(!engine.shouldIgnore(path: "regular_doc.pdf", name: "regular_doc.pdf", isDirectory: false, vaultId: testVaultId), "Regular files should NOT be ignored")
    print("  ✅ PASS: IgnoreRuleEngine correctly matches .nosync files and folders")
    
    // --- 3. User Exclusion (Right-click Exclude & Resume Sync) ---
    print("\n--- 3. Testing User Manual Exclusion & Resume ---")
    let testItemPath = "important_project/secret.dat"
    assert(!engine.isUserExcluded(vaultId: testVaultId, path: testItemPath), "Item should initially not be user-excluded")
    
    // User excludes item
    engine.setUserExcluded(vaultId: testVaultId, path: testItemPath, isExcluded: true)
    assert(engine.isUserExcluded(vaultId: testVaultId, path: testItemPath), "Item should be marked user-excluded")
    assert(engine.shouldIgnore(path: testItemPath, name: "secret.dat", isDirectory: false, vaultId: testVaultId), "User-excluded item should be ignored from remote sync")
    
    // User resumes sync
    engine.setUserExcluded(vaultId: testVaultId, path: testItemPath, isExcluded: false)
    assert(!engine.isUserExcluded(vaultId: testVaultId, path: testItemPath), "Item should no longer be user-excluded after resume")
    assert(!engine.shouldIgnore(path: testItemPath, name: "secret.dat", isDirectory: false, vaultId: testVaultId), "Resumed item should no longer be ignored")
    print("  ✅ PASS: User manual exclusion toggle (exclude & resume) works properly")
    
    // --- 4. SyncStatus.localOnly Semantics ---
    print("\n--- 4. Testing SyncStatus.localOnly Semantics ---")
    let localOnly = SyncStatus.localOnly
    assert(localOnly.isAvailableOffline, "localOnly must be available offline")
    assert(!localOnly.needsSync, "localOnly must NOT need sync")
    assert(localOnly.syncPriority == 0, "localOnly syncPriority must be 0 (no upload queueing)")
    print("  ✅ PASS: SyncStatus.localOnly is strictly local and does not trigger remote sync")
    
    // --- 5. FileMetadata and VirtualFileItem State for Excluded Items ---
    print("\n--- 5. Testing FileMetadata & VirtualFileItem with .localOnly ---")
    let fileId = "test_file_nosync_\(UUID().uuidString)"
    let metadata = FileMetadata(
        fileId: fileId,
        name: "test.nosync",
        parentId: "ROOT",
        isDirectory: false,
        syncStatus: .localOnly,
        localPath: "/tmp/test.nosync",
        remotePath: "/test.nosync",
        size: 1024,
        localModifiedAt: Date(),
        remoteModifiedAt: nil
    )
    assert(metadata.syncStatus == .localOnly, "FileMetadata retains localOnly sync status")
    assert(!metadata.hasConflict(), "localOnly cannot conflict with remote")
    
    let vfsItem = VirtualFileItem(
        id: fileId,
        name: "test.nosync",
        isDirectory: false,
        size: 1024,
        modifiedAt: Date(),
        parentId: "ROOT",
        syncStatus: .localOnly,
        localPath: "/tmp/test.nosync",
        remotePath: "/test.nosync"
    )
    assert(vfsItem.syncStatus == .localOnly, "VirtualFileItem retains localOnly sync status")
    print("  ✅ PASS: FileMetadata & VirtualFileItem correctly model excluded .localOnly items")
    
    print("\n✅ All Exclude from Sync (.nosync) regressions passed successfully!")
}
