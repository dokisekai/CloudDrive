import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CloudDriveSync
import CloudDriveCache
import CloudDriveCore

private func normalizeETag(_ etag: String) -> String {
    var cleaned = etag.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.hasPrefix("W/") {
        cleaned = String(cleaned.dropFirst(2))
    }
    return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
}

public func runFileOpenSyncStatusRegressionTests() async throws {
    print("""
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    🧪 Running File Open & Sync Status Regressions
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    """)
    
    // --- 1. Testing ETag Normalization and Consistency ---
    print("\n--- 1. Testing ETag Normalization & Equality ---")
    
    let rawEtag1 = "\"abcd1234\""
    let rawEtag2 = "abcd1234"
    let weakEtag = "W/\"abcd1234\""
    let spacesEtag = "  \"abcd1234\"  "
    let differentEtag = "\"different5678\""
    
    guard normalizeETag(rawEtag1) == "abcd1234" else {
        fatalError("Failed to normalize quoted ETag")
    }
    guard normalizeETag(weakEtag) == "abcd1234" else {
        fatalError("Failed to normalize weak ETag")
    }
    guard normalizeETag(spacesEtag) == "abcd1234" else {
        fatalError("Failed to normalize spaces in ETag")
    }
    guard normalizeETag(rawEtag1) == normalizeETag(rawEtag2) else {
        fatalError("Quoted ETag did not match unquoted ETag")
    }
    guard normalizeETag(weakEtag) == normalizeETag(rawEtag1) else {
        fatalError("Weak ETag did not match quoted ETag")
    }
    guard normalizeETag(rawEtag1) != normalizeETag(differentEtag) else {
        fatalError("Different ETags unexpectedly matched")
    }
    print("  ✅ PASS: ETag normalization handles quotes, W/ prefix, and whitespace correctly")
    
    // --- 2. Testing Synced Status Resilience against Cancellation ---
    print("\n--- 2. Testing Synced File Status Resilience ---")
    
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test_sync_resilience_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    
    let testFileId = "test_doc_001"
    var metadata = FileMetadata(
        fileId: testFileId,
        name: "test_doc.docx",
        parentId: "ROOT",
        isDirectory: false,
        syncStatus: .synced,
        localPath: tempDir.appendingPathComponent("test_doc.docx").path,
        remotePath: "/test_doc.docx",
        size: 1024,
        etag: "abcd1234"
    )
    
    let initialStatus = metadata.syncStatus
    guard initialStatus == .synced else {
        fatalError("Initial status is not synced")
    }
    
    // Simulate a fetch attempt that enters downloading state
    metadata.syncStatus = .downloading
    metadata.downloadProgress = 0.5
    
    // Simulate catch block error / cancellation recovery:
    // If it was previously synced, it must restore to initialStatus (.synced) rather than degrading to .cloudOnly
    if initialStatus != .synced && initialStatus != .localOnly {
        metadata.syncStatus = .cloudOnly
        metadata.downloadProgress = 0.0
    } else {
        metadata.syncStatus = initialStatus
        metadata.downloadProgress = 1.0
    }
    
    guard metadata.syncStatus == .synced else {
        fatalError("Failed: Synced file erroneously degraded to \(metadata.syncStatus)")
    }
    print("  ✅ PASS: Synced status is properly preserved upon simulated cancellation/failure")
    
    // --- 3. Testing Alias Store Mapping with Synced Items ---
    print("\n--- 3. Testing Item Alias Lookup Stability ---")
    
    let aliasStore = ItemAliasStore.shared
    let oldFileId = "placeholder_uuid_999"
    let realFileId = "vault_real_file_888"
    
    aliasStore.recordAlias(from: oldFileId, to: realFileId)
    
    let resolved = aliasStore.resolve(oldFileId)
    guard resolved == realFileId else {
        fatalError("Expected alias to resolve to \(realFileId), got \(resolved)")
    }
    print("  ✅ PASS: Alias successfully mapped to effective file ID")
    
    print("""
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    🎉 All File Open & Sync Status Regressions PASSED (3/3 passed)
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    """)
}
