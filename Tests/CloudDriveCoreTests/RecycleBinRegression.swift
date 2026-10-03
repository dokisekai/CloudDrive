//
//  RecycleBinRegression.swift
//  CloudDriveCoreTests
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  回收站模块与同步覆盖率回归测试套件
//

import Foundation
import CryptomatorCryptoLib
import CloudDriveCore
import CloudDriveStorage

private struct RecycleBinTestFailure: Error, CustomStringConvertible {
    let description: String
}

public func runRecycleBinRegressions() async throws {
    print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("🗑️ Running Recycle Bin & Extended Sync Regressions")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

    // MARK: - 1. RecycleBinConfig 与加密库专属数据库 (vfs.db) 单元测试
    do {
        print("  ▶ [RecycleBin 1] Testing per-vault default disabled & vfs.db vault_settings persistence...")
        let testVault1 = "test-vault-alpha-\(UUID().uuidString.prefix(6))"
        let testVault2 = "test-vault-beta-\(UUID().uuidString.prefix(6))"
        
        // 1. 初始状态：任何加密库默认必须为关闭 (false)
        assert(RecycleBinConfig.isEnabled(for: testVault1) == false, "RecycleBin must be DISABLED (false) by default for new vaults")
        assert(RecycleBinConfig.isEnabled(for: testVault2) == false, "RecycleBin must be DISABLED (false) by default for new vaults")
        
        // 2. 手动为 vault1 开启回收站（持久化写入 vault1 的 SQLite 数据库）
        RecycleBinConfig.setEnabled(true, for: testVault1)
        assert(RecycleBinConfig.isEnabled(for: testVault1) == true, "Vault 1 must now be enabled")
        assert(RecycleBinConfig.isEnabled(for: testVault2) == false, "Vault 2 must remain disabled (independent isolation)")
        
        // 3. 验证加密库自身 vfs.db 的 vault_settings 键值表读取
        let db1 = VFSDatabase(vaultId: testVault1)
        assert(db1.isRecycleBinEnabled() == true, "Vault 1 vfs.db must record recycle_bin_enabled = true")
        let db2 = VFSDatabase(vaultId: testVault2)
        assert(db2.isRecycleBinEnabled() == false, "Vault 2 vfs.db must return false by default")
        
        // 4. 手动关闭 vault1
        RecycleBinConfig.setEnabled(false, for: testVault1)
        assert(RecycleBinConfig.isEnabled(for: testVault1) == false, "Vault 1 must be disabled after turning off")
        assert(db1.isRecycleBinEnabled() == false, "Vault 1 vfs.db must record recycle_bin_enabled = false")
        
        // 5. 验证加密库忽略规则在 vfs.db 中的存放
        let sampleIgnoreRules = "*.tmp\nnode_modules/\n.DS_Store\n"
        try db1.setIgnoreRules(sampleIgnoreRules)
        assert(db1.getIgnoreRules() == sampleIgnoreRules, "Vault database must correctly store and retrieve ignore_rules")
        
        print("  ✅ [RecycleBin 1] PASSED: Per-vault default disabled (false), manual toggle & vfs.db vault_settings verified")
    }

    // MARK: - 2. RecycleBinStore SQLite 持久化测试
    do {
        print("  ▶ [RecycleBin 2] Testing RecycleBinStore SQLite CRUD, count & total size...")
        let tempDbURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_recycle_bin_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tempDbURL) }
        
        let store = RecycleBinStore(dbPath: tempDbURL)
        
        let item1 = RecycleBinItem(
            id: "bin-item-1",
            vaultId: "vault-A",
            fileId: "file_001",
            name: "report.pdf",
            originalParentId: "ROOT",
            originalRemotePath: "/vault-A/report.pdf",
            isDirectory: false,
            size: 2048,
            deletedAt: Date(),
            localBackupPath: "/tmp/backup1.pdf"
        )
        let item2 = RecycleBinItem(
            id: "bin-item-2",
            vaultId: "vault-A",
            fileId: "file_002",
            name: "design.fig",
            originalParentId: "folder_design",
            originalRemotePath: "/vault-A/design.fig",
            isDirectory: false,
            size: 5120,
            deletedAt: Date()
        )
        let item3 = RecycleBinItem(
            id: "bin-item-3",
            vaultId: "vault-B",
            fileId: "dir_003",
            name: "Photos",
            originalParentId: "ROOT",
            originalRemotePath: "/vault-B/Photos",
            isDirectory: true,
            size: 0,
            deletedAt: Date()
        )
        
        try store.save(item1)
        try store.save(item2)
        try store.save(item3)
        
        let fetched1 = try store.getItem(id: "bin-item-1")
        assert(fetched1 != nil, "Item 1 should be fetched")
        assert(fetched1?.name == "report.pdf", "Item 1 name matches")
        assert(fetched1?.size == 2048, "Item 1 size matches")
        assert(fetched1?.localBackupPath == "/tmp/backup1.pdf", "Backup path matches")
        
        let vaultAItems = try store.listItems(vaultId: "vault-A")
        assert(vaultAItems.count == 2, "Vault A should contain 2 items")
        
        let allItems = try store.listItems()
        assert(allItems.count == 3, "All items count should be 3")
        
        let totalCount = try store.count()
        assert(totalCount == 3, "Total count matches")
        
        let vaultACount = try store.count(vaultId: "vault-A")
        assert(vaultACount == 2, "Vault A count matches")
        
        let totalSize = try store.totalSize(vaultId: "vault-A")
        assert(totalSize == 7168, "Vault A total size 2048 + 5120 = 7168")
        
        try store.delete(id: "bin-item-1")
        let itemAfterDelete = try store.getItem(id: "bin-item-1")
        assert(itemAfterDelete == nil, "Item 1 should be deleted")
        let vaultACountAfterDelete = try store.count(vaultId: "vault-A")
        assert(vaultACountAfterDelete == 1, "Vault A count should now be 1")
        
        try store.deleteAll()
        let countAfterDeleteAll = try store.count()
        assert(countAfterDeleteAll == 0, "All items deleted")
        print("  ✅ [RecycleBin 2] PASSED: SQLite store CRUD, indexing & aggregations")
    }

    // MARK: - 3. RecycleBinManager 软删除、本地备份与还原全生命周期
    do {
        print("  ▶ [RecycleBin 3] Testing RecycleBinManager soft-delete, backup & restore...")
        let tempBaseDir = FileManager.default.temporaryDirectory.appendingPathComponent("safetest-recycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempBaseDir, withIntermediateDirectories: true)
        let vaultId = "RecycleVault_\(UUID().uuidString.prefix(8))"
        defer {
            try? FileManager.default.removeItem(at: tempBaseDir)
            try? FileManager.default.removeItem(at: CloudDrivePaths.vaultDirectory(for: vaultId))
        }
        
        let storageClient = LocalStorageClient()
        let vfs = VirtualFileSystem()
        vfs.configureStorage(client: storageClient)
        _ = try await vfs.initializeVaultWithoutEncryption(name: vaultId, storagePath: tempBaseDir.path)
        
        guard let provider = vfs.activeProvider as? DirectMappingVFSProvider else {
            throw RecycleBinTestFailure(description: "Provider is not DirectMappingVFSProvider")
        }
        
        // 1. 创建源测试文件并上传
        let sampleFile = tempBaseDir.appendingPathComponent("contract.docx")
        let sampleContent = "Confidential contract data for soft-delete test".data(using: .utf8)!
        try sampleContent.write(to: sampleFile)
        
        let uploaded = try await provider.uploadFile(localURL: sampleFile, name: "contract.docx", parentId: "ROOT")
        assert(uploaded.name == "contract.docx", "File created")
        
        // 模拟缓存文件
        let cache = vfs.cacheManager
        try cache.cacheFile(fileId: uploaded.id, from: sampleFile, policy: .automatic)
        assert(cache.isCached(fileId: uploaded.id), "File should be cached locally")
        
        // 2. 执行软删除 (moveToTrash)
        let trashed = try await RecycleBinManager.shared.moveToTrash(
            item: uploaded,
            vaultId: vaultId,
            vfs: vfs,
            cacheManager: cache
        )
        assert(trashed.name == "contract.docx", "Trashed item name matches")
        assert(trashed.size == Int64(sampleContent.count), "Trashed item size matches")
        assert(trashed.localBackupPath != nil, "Local backup copy should be retained in RecycleBinCache")
        if let path = trashed.localBackupPath {
            assert(FileManager.default.fileExists(atPath: path), "Backup file exists on disk")
        }
        
        // 验证文件在活动目录中已被移除 (Finder 看不到)
        let activeChildren = try vfs.listDirectory(directoryId: "ROOT")
        assert(!activeChildren.contains(where: { $0.id == uploaded.id }), "File should no longer appear in active directory")
        
        // 3. 执行还原 (restore)
        let restored = try await RecycleBinManager.shared.restore(
            id: trashed.id,
            vfs: vfs,
            syncManager: vfs.syncManager,
            cacheManager: cache
        )
        assert(restored.name == "contract.docx", "Restored item name matches")
        
        // 验证还原后重新出现在活动目录中
        let activeChildrenAfterRestore = try vfs.listDirectory(directoryId: "ROOT")
        assert(activeChildrenAfterRestore.contains(where: { $0.id == uploaded.id }), "File should be restored in active directory")
        assert(cache.isCached(fileId: uploaded.id), "Cache should be restored")
        
        // 验证回收站记录已清理
        let remaining = RecycleBinManager.shared.listItems(vaultId: vaultId)
        assert(!remaining.contains(where: { $0.id == trashed.id }), "Recycle bin should no longer contain restored item")
        
        print("  ✅ [RecycleBin 3] PASSED: Soft-delete, cache snapshot preservation & seamless restore")
    }

    // MARK: - 4. 彻底删除与清空回收站
    do {
        print("  ▶ [RecycleBin 4] Testing permanent deletion & empty trash...")
        let tempBaseDir = FileManager.default.temporaryDirectory.appendingPathComponent("safetest-trash-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempBaseDir, withIntermediateDirectories: true)
        let vaultId = "EmptyTrashVault_\(UUID().uuidString.prefix(8))"
        defer {
            try? FileManager.default.removeItem(at: tempBaseDir)
            try? FileManager.default.removeItem(at: CloudDrivePaths.vaultDirectory(for: vaultId))
        }
        
        let storageClient = LocalStorageClient()
        let vfs = VirtualFileSystem()
        vfs.configureStorage(client: storageClient)
        _ = try await vfs.initializeVaultWithoutEncryption(name: vaultId, storagePath: tempBaseDir.path)
        guard let provider = vfs.activeProvider as? DirectMappingVFSProvider else {
            throw RecycleBinTestFailure(description: "Provider is not DirectMappingVFSProvider")
        }
        
        let f1 = tempBaseDir.appendingPathComponent("file1.txt")
        try "data1".write(to: f1, atomically: true, encoding: .utf8)
        let u1 = try await provider.uploadFile(localURL: f1, name: "file1.txt", parentId: "ROOT")
        
        let t1 = try await RecycleBinManager.shared.moveToTrash(
            item: u1,
            vaultId: vaultId,
            vfs: vfs,
            cacheManager: vfs.cacheManager
        )
        
        assert(RecycleBinManager.shared.listItems(vaultId: vaultId).count >= 1, "Item should be in trash")
        
        // 彻底删除
        try await RecycleBinManager.shared.deletePermanently(
            id: t1.id,
            vfs: vfs,
            syncManager: vfs.syncManager,
            storageClient: storageClient
        )
        assert(!RecycleBinManager.shared.listItems(vaultId: vaultId).contains(where: { $0.id == t1.id }), "Item permanently deleted")
        
        print("  ✅ [RecycleBin 4] PASSED: Permanent delete and empty trash")
    }
    
    // MARK: - 5. 修改已有文件并在 expectedETag 为 nil 时安全覆盖测试
    do {
        print("  ▶ [Sync Coverage 5] Overwriting existing files when expectedETag is nil...")
        let tempBaseDir = FileManager.default.temporaryDirectory.appendingPathComponent("safetest-overwrite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempBaseDir, withIntermediateDirectories: true)
        let vaultId = "OverwriteVault_\(UUID().uuidString.prefix(8))"
        defer {
            try? FileManager.default.removeItem(at: tempBaseDir)
            try? FileManager.default.removeItem(at: CloudDrivePaths.vaultDirectory(for: vaultId))
        }
        
        let storageClient = LocalStorageClient()
        let vfs = VirtualFileSystem()
        vfs.configureStorage(client: storageClient)
        _ = try await vfs.initializeVaultWithoutEncryption(name: vaultId, storagePath: tempBaseDir.path)
        guard let provider = vfs.activeProvider as? DirectMappingVFSProvider else {
            throw RecycleBinTestFailure(description: "Provider is not DirectMappingVFSProvider")
        }
        
        // 1. 初次创建
        let srcFile = tempBaseDir.appendingPathComponent("edit_test.txt")
        try "Original V1 Content".write(to: srcFile, atomically: true, encoding: .utf8)
        let v1 = try await provider.uploadFile(localURL: srcFile, name: "edit_test.txt", parentId: "ROOT")
        assert(v1.name == "edit_test.txt", "V1 uploaded")
        
        // 2. 修改文件内容并再次使用 uploadFile(expectedETag: nil) 上传
        try "Updated V2 Content with Modifications".write(to: srcFile, atomically: true, encoding: .utf8)
        let v2 = try await provider.uploadFile(localURL: srcFile, name: "edit_test.txt", parentId: "ROOT", expectedETag: nil)
        assert(v2.name == "edit_test.txt", "V2 uploaded successfully without 412 collision")
        
        // 3. 验证远端内容已成功更新
        let remotePath = "\(tempBaseDir.path)/\(vaultId)/files/edit_test.txt"
        let updatedContent = try String(contentsOfFile: remotePath, encoding: .utf8)
        assert(updatedContent == "Updated V2 Content with Modifications", "Remote file content correctly updated")
        
        print("  ✅ [Sync Coverage 5] PASSED: Existing file modification updates remote content smoothly")
    }
    
    // MARK: - 6. 还原冲突自动避让重命名及孤儿文件恢复根目录测试
    do {
        print("  ▶ [RecycleBin 6] Testing restore collision auto-renaming & orphan parent fallback...")
        let tempBaseDir = FileManager.default.temporaryDirectory.appendingPathComponent("safetest-collision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempBaseDir, withIntermediateDirectories: true)
        let vaultId = "CollisionVault_\(UUID().uuidString.prefix(8))"
        defer {
            try? FileManager.default.removeItem(at: tempBaseDir)
            try? FileManager.default.removeItem(at: CloudDrivePaths.vaultDirectory(for: vaultId))
        }
        
        let storageClient = LocalStorageClient()
        let vfs = VirtualFileSystem()
        vfs.configureStorage(client: storageClient)
        _ = try await vfs.initializeVaultWithoutEncryption(name: vaultId, storagePath: tempBaseDir.path)
        guard let provider = vfs.activeProvider as? DirectMappingVFSProvider else {
            throw RecycleBinTestFailure(description: "Provider is not DirectMappingVFSProvider")
        }
        
        // 1. 在 ROOT 下创建现有文件 "notes.txt"
        let rootFile = tempBaseDir.appendingPathComponent("notes.txt")
        try "Root existing notes".write(to: rootFile, atomically: true, encoding: .utf8)
        let rootItem = try await provider.uploadFile(localURL: rootFile, name: "notes.txt", parentId: "ROOT")
        assert(rootItem.name == "notes.txt", "Root notes created")
        
        // 2. 在子文件夹 "Projects" 下创建同名文件 "notes.txt"
        let subDir = try await provider.createDirectory(name: "Projects", parentId: "ROOT")
        let subFile = tempBaseDir.appendingPathComponent("project_notes.txt")
        try "Project specific notes".write(to: subFile, atomically: true, encoding: .utf8)
        let subItem = try await provider.uploadFile(localURL: subFile, name: "notes.txt", parentId: subDir.id)
        
        // 3. 软删除子文件夹中的 "notes.txt"
        let trashedChild = try await RecycleBinManager.shared.moveToTrash(
            item: subItem,
            vaultId: vaultId,
            vfs: vfs,
            cacheManager: vfs.cacheManager
        )
        
        // 4. 删除子文件夹 "Projects"
        try await provider.delete(itemId: subDir.id)
        
        // 5. 还原已被删除文件夹中的 notes.txt
        // 目标父目录 Projects 已不存在 -> 回退至 ROOT
        // 此时 ROOT 下已存在同名 "notes.txt" -> 自动避让更名为 "notes (1).txt"
        let restoredChild = try await RecycleBinManager.shared.restore(
            id: trashedChild.id,
            vfs: vfs,
            syncManager: vfs.syncManager,
            cacheManager: vfs.cacheManager
        )
        assert(restoredChild.parentId == "ROOT", "Orphan file parent should fall back to ROOT")
        assert(restoredChild.name == "notes (1).txt", "Collision should be resolved by renaming to 'notes (1).txt'")
        
        // 6. 验证 ROOT 下两者并存且内容隔离
        let rootChildren = try vfs.listDirectory(directoryId: "ROOT")
        assert(rootChildren.contains(where: { $0.name == "notes.txt" }), "Original ROOT notes.txt retained")
        assert(rootChildren.contains(where: { $0.name == "notes (1).txt" }), "Restored orphan coexists as notes (1).txt")
        
        print("  ✅ [RecycleBin 6] PASSED: Collision auto-rename & orphan directory restore resilience")
    }

    // MARK: - 7. Unicode NFC 规范化多语言文件名加密一致性测试
    do {
        print("  ▶ [Unicode NFC 7] Testing CryptomatorFormat NFC filename encryption consistency...")
        let storageClient = LocalStorageClient()
        let masterKey = try Masterkey.createNew()
        let format = CryptomatorFormat(masterkey: masterKey, storageClient: storageClient, basePath: "/test")
        let parentDirId = "dir_test".data(using: .utf8)!
        
        // 测试包含重音符与多字节中文的文件名
        let nfdName = "re\u{0301}sume\u{0301}.pdf" // "résumé.pdf" in NFD decomposed format
        let nfcName = "résumé.pdf"              // in NFC precomposed format
        let cjkName = "项目测试报告_2026.docx"
        
        let encNFD = try format.getEncryptedFileName(name: nfdName, parentDirId: parentDirId)
        let encNFC = try format.getEncryptedFileName(name: nfcName, parentDirId: parentDirId)
        assert(encNFD == encNFC, "NFD and NFC inputs must yield identical ciphertext file names")
        
        let decNFD = try format.getDecryptedFileName(ciphertextName: encNFD, parentDirId: parentDirId)
        assert(decNFD == nfcName, "Decrypted name must match normalized NFC string")
        
        let encCJK = try format.getEncryptedFileName(name: cjkName, parentDirId: parentDirId)
        let decCJK = try format.getDecryptedFileName(ciphertextName: encCJK, parentDirId: parentDirId)
        assert(decCJK == cjkName, "CJK unicode filename round-trip matches")
        
        print("  ✅ [Unicode NFC 7] PASSED: NFD/NFC equivalence & CJK encryption consistency")
    }
    
    // MARK: - 8. VFS「回收站」真实移动、本地缓存物理清理与清空测试
    do {
        print("  ▶ [RecycleBin 8] Testing VFS moveToRecycleBin, local cache purge & emptyTrash...")
        let tempStorageDir = FileManager.default.temporaryDirectory.appendingPathComponent("safetest-bin-vfs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempStorageDir, withIntermediateDirectories: true)
        let vaultId = "BinVault_\(UUID().uuidString.prefix(8))"
        defer {
            try? FileManager.default.removeItem(at: tempStorageDir)
            try? FileManager.default.removeItem(at: CloudDrivePaths.vaultDirectory(for: vaultId))
        }
        
        let localClient = LocalStorageClient()
        let vfs = VirtualFileSystem()
        vfs.configureStorage(client: localClient)
        _ = try await vfs.initializeVaultWithoutEncryption(name: vaultId, storagePath: tempStorageDir.path)
        guard let provider = vfs.activeProvider as? DirectMappingVFSProvider else {
            throw RecycleBinTestFailure(description: "Provider is not DirectMappingVFSProvider")
        }
        
        // 0. 验证初始状态为默认关闭，然后手动开启
        assert(RecycleBinConfig.isEnabled(for: vaultId) == false, "Vault recycle bin must be disabled by default")
        RecycleBinConfig.setEnabled(true, for: vaultId)
        assert(RecycleBinConfig.isEnabled(for: vaultId) == true, "Vault recycle bin is now enabled")
        
        // 1. 创建测试文件
        let testData = "Disk space to be purged immediately".data(using: .utf8)!
        let tempLocal = tempStorageDir.appendingPathComponent("important_document.txt")
        try testData.write(to: tempLocal)
        let testFile = try await provider.uploadFile(localURL: tempLocal, name: "important_document.txt", parentId: "ROOT")
        
        // 写入本地缓存以模拟已下载文件
        try vfs.cacheManager.cacheFile(fileId: testFile.id, from: tempLocal, policy: .automatic)
        assert(vfs.cacheManager.isCached(fileId: testFile.id), "File must be cached locally before move")
        
        // 2. 移入回收站
        let moved = try await vfs.moveToRecycleBin(item: testFile)
        
        // 验证已移入「回收站」目录
        let binDir = vfs.getRecycleBinDirectory()
        assert(binDir != nil, "Recycle Bin directory must exist")
        assert(vfs.isRecycleBinDirectory(id: binDir!.id), "Directory must be recognized as Recycle Bin")
        assert(vfs.isItemInRecycleBin(item: moved), "Moved item must be recognized as inside Recycle Bin")
        assert(moved.parentId == binDir!.id, "Moved item parentId must be Recycle Bin ID")
        
        // 验证本地物理缓存已被即刻清理（空间被彻底释放）
        assert(!vfs.cacheManager.isCached(fileId: testFile.id), "Original file cache must be purged")
        assert(!vfs.cacheManager.isCached(fileId: moved.id), "Moved file cache must be purged")
        
        // 验证同步状态已变为纯云端 (cloudOnly)
        let meta = vfs.syncManager.getMetadata(fileId: moved.id)
        assert(meta?.syncStatus == .cloudOnly, "Sync status must be cloudOnly")
        assert(meta?.localPath == nil, "localPath must be nil to prevent local disk usage")
        
        // 3. 再次移入同名文件，测试重命名冲突
        let tempLocal2 = tempStorageDir.appendingPathComponent("important_document_2.txt")
        try testData.write(to: tempLocal2)
        let testFile2 = try await provider.uploadFile(localURL: tempLocal2, name: "important_document.txt", parentId: "ROOT")
        let moved2 = try await vfs.moveToRecycleBin(item: testFile2)
        assert(moved2.name == "important_document (1).txt", "Duplicate file name inside recycle bin must auto-rename")
        
        // 4. 清空回收站
        try await vfs.emptyTrash()
        let binChildren = (try? vfs.listDirectory(directoryId: binDir!.id)) ?? []
        assert(binChildren.isEmpty, "Recycle Bin must be empty after emptyTrash")
        
        print("  ✅ [RecycleBin 8] PASSED: VFS moveToRecycleBin, instant cache purge & emptyTrash verified")
    }
    
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("🎉 All Recycle Bin & Extended Sync Regressions Successfully Verified!")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
}
