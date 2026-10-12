//
//  ProgressPublisherRegression.swift
//  CloudDriveTestsRunner
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  原生进度发布器与文件夹层级进度聚合器 (iCloud 体验) 回归测试
//

import Foundation
import CloudDriveCore
import CloudDriveContracts
import CloudDriveSystem
import CloudDriveSupport
import CloudDriveStorage

func runProgressPublisherRegressionTests() async throws {
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("🧪 Running Finder Progress & Folder Roll-Up Regressions")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    
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
    
    // ----------------------------------------------------
    // 1. DirectMapping & Encrypted 相对路径解析测试
    // ----------------------------------------------------
    print("\n--- 1. Testing Relative Path Resolution ---")
    do {
        // Direct mapping
        let syncService = SyncService(vaultId: "test-direct-vault")
        let rootPath = syncService.resolveRelativePath(fileId: "f0", name: "photo.jpg", parentId: "ROOT")
        assert(rootPath == "photo.jpg", "Root directory file resolves to filename only")
        
        let subPath = syncService.resolveRelativePath(fileId: "f1", name: "doc.pdf", parentId: "/Documents/Work")
        assert(subPath == "Documents/Work/doc.pdf", "Direct mapping nested parentId resolves to 'Documents/Work/doc.pdf'")
        
        let remotePathResolved = syncService.resolveRelativePath(fileId: "f2", name: "archive.zip", remotePath: "/Backup/2026/archive.zip")
        assert(remotePathResolved == "Backup/2026/archive.zip", "Remote path strips leading slash and resolves full relative path")
        
        // Encrypted VFS walking
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("progress_vfs_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let vfs = VirtualFileSystem()
        vfs.configureStorage(client: LocalStorageClient())
        _ = try await vfs.initializeVault(name: "EncProgressVault", password: "Password123!", storagePath: tempDir.path)
        
        // Setup hierarchy in database: ROOT -> dirA (Photos) -> dirB (2026) -> file (summer.jpg)
        try vfs.database.directoryRepo.insertDirectory(id: "dirA", name: "Photos", parentId: "ROOT", encryptedId: "encA", remotePath: "/encA")
        try vfs.database.directoryRepo.insertDirectory(id: "dirB", name: "2026", parentId: "dirA", encryptedId: "encB", remotePath: "/encB")
        
        let resolvedEncPath = vfs.resolveRelativePath(name: "summer.jpg", parentId: "dirB")
        assert(resolvedEncPath == "Photos/2026/summer.jpg", "Encrypted VFS recursively walks database to produce 'Photos/2026/summer.jpg'")
        
        let rootEncPath = vfs.resolveRelativePath(name: "root.txt", parentId: "ROOT")
        assert(rootEncPath == "root.txt", "Encrypted VFS root file produces 'root.txt'")
    }
    
    // ----------------------------------------------------
    // 2. FolderProgressAggregator 祖先目录层级聚合测试
    // ----------------------------------------------------
    print("\n--- 2. Testing FolderProgressAggregator Hierarchical Roll-Up ---")
    do {
        let aggregator = FolderProgressAggregator.shared
        aggregator.reset()
        
        let mockMountRoot = URL(fileURLWithPath: "/tmp/MockCloudStorage/CloudDrive-Vault")
        let folderA = mockMountRoot.appendingPathComponent("FolderA")
        let folderB = folderA.appendingPathComponent("FolderB")
        let file1URL = folderB.appendingPathComponent("file1.dat")
        let file2URL = folderB.appendingPathComponent("file2.dat")
        let file3URL = folderA.appendingPathComponent("file3.dat")
        
        // File 1 starts (1000 bytes)
        aggregator.fileDidStart(
            fileId: "f1",
            fileURL: file1URL,
            mountRootURL: mockMountRoot,
            totalBytes: 1000,
            kind: .uploading
        )
        
        let activePathsAfterF1 = aggregator.getActiveFolderPaths()
        assert(activePathsAfterF1.contains(folderA.standardizedFileURL.path.precomposedStringWithCanonicalMapping), "FolderA is activated on nested file start")
        assert(activePathsAfterF1.contains(folderB.standardizedFileURL.path.precomposedStringWithCanonicalMapping), "FolderB is activated on nested file start")
        assert(!activePathsAfterF1.contains(mockMountRoot.standardizedFileURL.path.precomposedStringWithCanonicalMapping), "Mount root itself is excluded from folder roll-up (handled by sidebar)")
        
        if let progB = aggregator.getFolderProgress(for: folderB.path) {
            assert(progB.totalBytes == 1000 && progB.completedBytes == 0, "FolderB initial progress is 0/1000")
        } else {
            assert(false, "FolderB progress exists")
        }
        
        // File 2 starts (2000 bytes) in FolderB
        aggregator.fileDidStart(
            fileId: "f2",
            fileURL: file2URL,
            mountRootURL: mockMountRoot,
            totalBytes: 2000,
            kind: .uploading
        )
        
        if let progB = aggregator.getFolderProgress(for: folderB.path) {
            assert(progB.totalBytes == 3000 && progB.completedBytes == 0, "FolderB aggregates total across File1 and File2 (3000 bytes)")
        }
        
        // File 3 starts (5000 bytes) in FolderA directly
        aggregator.fileDidStart(
            fileId: "f3",
            fileURL: file3URL,
            mountRootURL: mockMountRoot,
            totalBytes: 5000,
            kind: .uploading
        )
        
        if let progA = aggregator.getFolderProgress(for: folderA.path) {
            assert(progA.totalBytes == 8000, "FolderA aggregates all children (1000 + 2000 + 5000 = 8000 bytes)")
        }
        
        // Update progress on File 1 (500 bytes)
        aggregator.fileDidUpdate(fileId: "f1", completedBytes: 500)
        if let progB = aggregator.getFolderProgress(for: folderB.path) {
            assert(progB.completedBytes == 500, "FolderB completedBytes advances to 500")
        }
        if let progA = aggregator.getFolderProgress(for: folderA.path) {
            assert(progA.completedBytes == 500, "FolderA completedBytes advances to 500")
        }
        
        // Update progress on File 2 (2000 bytes completed)
        aggregator.fileDidUpdate(fileId: "f2", completedBytes: 2000)
        if let progB = aggregator.getFolderProgress(for: folderB.path) {
            assert(progB.completedBytes == 2500, "FolderB completedBytes advances to 2500 / 3000")
        }
        
        // Finish File 1 (1000 bytes)
        aggregator.fileDidFinish(fileId: "f1")
        if let progB = aggregator.getFolderProgress(for: folderB.path) {
            assert(progB.completedBytes >= 2500, "FolderB progress is monotonic after File 1 finishes")
        }
        
        // Finish File 2
        aggregator.fileDidFinish(fileId: "f2")
        // FolderB now has zero active items, but enters debounce window
        if let progB = aggregator.getFolderProgress(for: folderB.path) {
            assert(progB.completedBytes == progB.totalBytes, "FolderB reaches 100% on completion before debounce unpublish")
        }
        
        // Finish File 3
        aggregator.fileDidFinish(fileId: "f3")
        
        // Wait for debounce unpublish (300ms + buffer)
        try await Task.sleep(nanoseconds: 450_000_000)
        
        let remainingPaths = aggregator.getActiveFolderPaths()
        assert(remainingPaths.isEmpty, "All ancestor folders safely unpublished after debounce window (no orphaned progress)")
    }
    
    // ----------------------------------------------------
    // 3. FileProgressPublisher 端到端发布与联动测试
    // ----------------------------------------------------
    print("\n--- 3. Testing FileProgressPublisher End-to-End Pipeline ---")
    do {
        let publisher = FileProgressPublisher.shared
        let aggregator = FolderProgressAggregator.shared
        aggregator.reset()
        
        let mockRoot = URL(fileURLWithPath: "/tmp/MockCloudStorage/CloudDrive-E2E")
        let subURL = mockRoot.appendingPathComponent("Reports/Q3")
        let fileURL = subURL.appendingPathComponent("financial.xlsx")
        
        // Start progress
        publisher.startProgress(
            fileId: "report-q3",
            fileName: "financial.xlsx",
            relativePath: "Reports/Q3/financial.xlsx",
            vaultId: "e2e-vault",
            userVisibleURL: fileURL,
            totalBytes: 50_000,
            kind: .uploading
        )
        
        let activeTransfers = publisher.getActiveTransfers()
        assert(activeTransfers.contains(where: { $0.id == "report-q3" }), "ActiveTransferInfo tracked in FileProgressPublisher")
        
        let folderPaths = aggregator.getActiveFolderPaths()
        assert(folderPaths.contains(subURL.standardizedFileURL.path.precomposedStringWithCanonicalMapping), "Subfolder Reports/Q3 has active NSProgress")
        assert(folderPaths.contains(subURL.deletingLastPathComponent().standardizedFileURL.path.precomposedStringWithCanonicalMapping), "Parent folder Reports has active NSProgress")
        
        // Update progress
        publisher.updateProgress(fileId: "report-q3", completedBytes: 25_000)
        if let updatedInfo = publisher.getActiveTransfers().first(where: { $0.id == "report-q3" }) {
            assert(updatedInfo.completedBytes == 25_000, "Active transfer completedBytes updated to 25000")
            assert(updatedInfo.progressFraction == 0.5, "Active transfer fraction is exactly 0.5")
        }
        
        // Finish progress
        publisher.finishProgress(fileId: "report-q3")
        assert(!publisher.getActiveTransfers().contains(where: { $0.id == "report-q3" }), "Active transfer removed after finishProgress")
        
        // Verify aggregator unpublishes after debounce
        try await Task.sleep(nanoseconds: 450_000_000)
        assert(aggregator.getActiveFolderPaths().isEmpty, "Aggregator cleaned up all folders after transfer completed")
    }
    
    // ----------------------------------------------------
    // 4. Unicode 多语言与特殊符号路径规范化验证
    // ----------------------------------------------------
    print("\n--- 4. Testing Unicode & CJK Path Normalization ---")
    do {
        let aggregator = FolderProgressAggregator.shared
        aggregator.reset()
        
        let mockRoot = URL(fileURLWithPath: "/tmp/MockCloudStorage/CloudDrive-Unicode")
        let cjkFolder = mockRoot.appendingPathComponent("财务报表 (2026年)")
        let cjkSubFolder = cjkFolder.appendingPathComponent("第三季度·核心数据")
        let cjkFileURL = cjkSubFolder.appendingPathComponent("收入明细_ü_é.xlsx")
        
        aggregator.fileDidStart(
            fileId: "cjk-file-1",
            fileURL: cjkFileURL,
            mountRootURL: mockRoot,
            totalBytes: 88_888,
            kind: .uploading
        )
        
        let active = aggregator.getActiveFolderPaths()
        let canonicalSub = cjkSubFolder.standardizedFileURL.path.precomposedStringWithCanonicalMapping
        let canonicalParent = cjkFolder.standardizedFileURL.path.precomposedStringWithCanonicalMapping
        
        assert(active.contains(canonicalSub), "CJK and accented subfolder correctly activated")
        assert(active.contains(canonicalParent), "CJK parent folder correctly activated")
        
        aggregator.fileDidFinish(fileId: "cjk-file-1")
        try await Task.sleep(nanoseconds: 450_000_000)
        assert(aggregator.getActiveFolderPaths().isEmpty, "CJK folders cleanly unpublished after transfer")
    }
    
    // ----------------------------------------------------
    // 5. 幂等性防护与重复启动检测 (Idempotent Retry Safety)
    // ----------------------------------------------------
    print("\n--- 5. Testing Idempotent fileDidStart Retry Safety ---")
    do {
        let aggregator = FolderProgressAggregator.shared
        aggregator.reset()
        
        let mockRoot = URL(fileURLWithPath: "/tmp/MockCloudStorage/CloudDrive-Retry")
        let folder = mockRoot.appendingPathComponent("AutoRetry")
        let fileURL = folder.appendingPathComponent("data.bin")
        
        // First start (1000 bytes)
        aggregator.fileDidStart(fileId: "retry-1", fileURL: fileURL, mountRootURL: mockRoot, totalBytes: 1000, kind: .uploading)
        if let prog = aggregator.getFolderProgress(for: folder.path) {
            assert(prog.totalBytes == 1000, "Initial retry test total is 1000")
        }
        
        // Simulated network failure & immediate retry without finishing (e.g. queue re-attempt with adjusted size 1500)
        aggregator.fileDidStart(fileId: "retry-1", fileURL: fileURL, mountRootURL: mockRoot, totalBytes: 1500, kind: .uploading)
        if let prog = aggregator.getFolderProgress(for: folder.path) {
            assert(prog.totalBytes == 1500, "Idempotent restart replaces old total without double-counting (1500, not 2500)")
        }
        
        aggregator.fileDidFinish(fileId: "retry-1")
        try await Task.sleep(nanoseconds: 450_000_000)
        assert(aggregator.getActiveFolderPaths().isEmpty, "Cleaned up retry folders completely")
    }
    
    // ----------------------------------------------------
    // 6. 生命周期管理与指定 Vault 批量强制清理验证
    // ----------------------------------------------------
    print("\n--- 6. Testing Vault-Scoped Lifecycle Cancellation ---")
    do {
        let publisher = FileProgressPublisher.shared
        let aggregator = FolderProgressAggregator.shared
        aggregator.reset()
        
        let rootA = URL(fileURLWithPath: "/tmp/MockCloudStorage/CloudDrive-VaultA")
        let rootB = URL(fileURLWithPath: "/tmp/MockCloudStorage/CloudDrive-VaultB")
        
        let fileA = rootA.appendingPathComponent("FolderA/itemA.txt")
        let fileB = rootB.appendingPathComponent("FolderB/itemB.txt")
        
        publisher.startProgress(fileId: "vA-1", fileName: "itemA.txt", relativePath: "FolderA/itemA.txt", vaultId: "vault-A", userVisibleURL: fileA, totalBytes: 2000, kind: .uploading)
        publisher.startProgress(fileId: "vB-1", fileName: "itemB.txt", relativePath: "FolderB/itemB.txt", vaultId: "vault-B", userVisibleURL: fileB, totalBytes: 3000, kind: .uploading)
        
        assert(publisher.getActiveTransfers().count == 2, "Two concurrent transfers across VaultA and VaultB")
        
        // Cancel Vault A (simulating vault lock or domain unmount of Vault A)
        publisher.cancelTransfers(for: "vault-A")
        aggregator.unpublishAll(under: rootA)
        
        let remainingTransfers = publisher.getActiveTransfers()
        assert(remainingTransfers.count == 1 && remainingTransfers.first?.id == "vB-1", "VaultA transfers cancelled, VaultB retained")
        
        // Clean up remaining
        publisher.cancelTransfers()
        aggregator.reset()
        assert(publisher.getActiveTransfers().isEmpty, "All transfers completely purged")
    }
    
    // ----------------------------------------------------
    // 7. 0 字节空文件极端边界防护测试
    // ----------------------------------------------------
    print("\n--- 7. Testing 0-Byte Empty File Handling ---")
    do {
        let publisher = FileProgressPublisher.shared
        let aggregator = FolderProgressAggregator.shared
        aggregator.reset()
        
        let root = URL(fileURLWithPath: "/tmp/MockCloudStorage/CloudDrive-ZeroByte")
        let fileURL = root.appendingPathComponent("EmptyFolder/empty.txt")
        
        let prog = publisher.startProgress(fileId: "zero-file", fileName: "empty.txt", relativePath: "EmptyFolder/empty.txt", vaultId: "zb-vault", userVisibleURL: fileURL, totalBytes: 0, kind: .uploading)
        assert(prog.totalUnitCount == 100, "0-byte file defaults to 100 base units safely")
        
        publisher.updateProgress(fileId: "zero-file", completedBytes: 0)
        assert(prog.completedUnitCount == 0, "0-byte file completed unit is 0 initially")
        
        publisher.finishProgress(fileId: "zero-file")
        try await Task.sleep(nanoseconds: 450_000_000)
        assert(aggregator.getActiveFolderPaths().isEmpty, "0-byte file finished and cleaned up without exceptions")
    }
    
    print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    if failed == 0 {
        print("🎉 ALL Finder Progress & Folder Roll-Up Regressions Passed (\(passed) passed)")
    } else {
        print("❌ Finder Progress Regressions FAILED (\(passed) passed, \(failed) failed)")
        exit(1)
    }
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
}
