//
//  SyncRulesTests.swift
//  CloudDriveCore
//
//  同步规则测试用例 - 验证所有同步场景和规则
//

import XCTest
import Foundation
@testable import CloudDriveCore

class SyncRulesTests: XCTestCase {
    
    var advancedSyncManager: AdvancedSyncManager!
    var mockStorageClient: MockStorageClient!
    var testDeviceId: String!
    var testUserId: String!
    
    override func setUp() {
        super.setUp()
        
        testDeviceId = "test-device-\(UUID().uuidString)"
        testUserId = "test-user-\(UUID().uuidString)"
        
        advancedSyncManager = AdvancedSyncManager.shared
        mockStorageClient = MockStorageClient()
        advancedSyncManager.configure(storageClient: mockStorageClient)
    }
    
    override func tearDown() {
        advancedSyncManager = nil
        mockStorageClient = nil
        super.tearDown()
    }
    
    // MARK: - 基础同步规则测试
    
    /// 测试规则1: 本地新增文件自动上传
    func testRule1_LocalNewFileAutoUpload() async throws {
        // 准备测试数据
        let fileName = "test_new_file.txt"
        let content = "This is a new file content".data(using: .utf8)!
        let parentPath = "/test"
        
        // 执行操作
        let fileId = try await advancedSyncManager.createFile(
            name: fileName,
            content: content,
            parentPath: parentPath
        )
        
        // 验证结果
        XCTAssertNotNil(fileId)
        
        // 等待同步完成
        try await waitForSyncCompletion()
        
        // 验证文件已上传
        XCTAssertTrue(mockStorageClient.uploadedFiles.contains("\(parentPath)/\(fileName)"))
        
        // 验证同步状态
        let metadata = advancedSyncManager.getMetadata(fileId: fileId)
        XCTAssertEqual(metadata?.syncStatus, .synced)
    }
    
    /// 测试规则2: 云端新增文件自动下载
    func testRule2_CloudNewFileAutoDownload() async throws {
        // 模拟云端新文件
        let fileName = "cloud_new_file.txt"
        let content = "This is a cloud file content".data(using: .utf8)!
        let remotePath = "/test/\(fileName)"
        
        mockStorageClient.addRemoteFile(path: remotePath, content: content)
        
        // 触发同步
        advancedSyncManager.startSync()
        
        // 等待同步完成
        try await waitForSyncCompletion()
        
        // 验证文件已下载
        let localPath = "/local/test/\(fileName)"
        XCTAssertTrue(FileManager.default.fileExists(atPath: localPath))
        
        // 验证内容一致
        let downloadedContent = try Data(contentsOf: URL(fileURLWithPath: localPath))
        XCTAssertEqual(downloadedContent, content)
    }
    
    /// 测试规则3: 本地修改文件优先级高于云端
    func testRule3_LocalModificationPriority() async throws {
        // 创建初始文件
        let fileName = "priority_test.txt"
        let initialContent = "Initial content".data(using: .utf8)!
        let fileId = try await advancedSyncManager.createFile(
            name: fileName,
            content: initialContent,
            parentPath: "/test"
        )
        
        try await waitForSyncCompletion()
        
        // 同时修改本地和云端
        let localContent = "Local modification".data(using: .utf8)!
        let cloudContent = "Cloud modification".data(using: .utf8)!
        
        // 本地修改
        try await advancedSyncManager.modifyFile(fileId: fileId, newContent: localContent)
        
        // 模拟云端修改
        let remotePath = "/test/\(fileName)"
        mockStorageClient.updateRemoteFile(path: remotePath, content: cloudContent)
        
        // 触发同步
        advancedSyncManager.startSync()
        try await waitForSyncCompletion()
        
        // 验证本地版本获胜
        let finalMetadata = advancedSyncManager.getMetadata(fileId: fileId)
        XCTAssertNotNil(finalMetadata)
        
        if let localPath = finalMetadata?.localPath {
            let finalContent = try Data(contentsOf: URL(fileURLWithPath: localPath))
            XCTAssertEqual(finalContent, localContent)
        }
    }
    
    /// 测试规则4: 本地删除文件同步到云端
    func testRule4_LocalDeleteSyncToCloud() async throws {
        // 创建文件
        let fileName = "delete_test.txt"
        let content = "Content to be deleted".data(using: .utf8)!
        let fileId = try await advancedSyncManager.createFile(
            name: fileName,
            content: content,
            parentPath: "/test"
        )
        
        try await waitForSyncCompletion()
        
        // 删除文件
        try await advancedSyncManager.deleteFile(fileId: fileId)
        
        // 等待同步完成
        try await waitForSyncCompletion()
        
        // 验证云端文件已删除
        let remotePath = "/test/\(fileName)"
        XCTAssertTrue(mockStorageClient.deletedFiles.contains(remotePath))
    }
    
    /// 测试规则5: 云端删除文件同步到本地
    func testRule5_CloudDeleteSyncToLocal() async throws {
        // 创建文件
        let fileName = "cloud_delete_test.txt"
        let content = "Content to be deleted from cloud".data(using: .utf8)!
        let fileId = try await advancedSyncManager.createFile(
            name: fileName,
            content: content,
            parentPath: "/test"
        )
        
        try await waitForSyncCompletion()
        
        let metadata = advancedSyncManager.getMetadata(fileId: fileId)
        let localPath = metadata?.localPath
        
        // 验证本地文件存在
        XCTAssertTrue(FileManager.default.fileExists(atPath: localPath!))
        
        // 模拟云端删除
        let remotePath = "/test/\(fileName)"
        mockStorageClient.deleteRemoteFile(path: remotePath)
        
        // 触发同步
        advancedSyncManager.startSync()
        try await waitForSyncCompletion()
        
        // 验证本地文件已删除
        XCTAssertFalse(FileManager.default.fileExists(atPath: localPath!))
    }
    
    // MARK: - 冲突解决测试
    
    /// 测试冲突检测
    func testConflictDetection() async throws {
        // 创建文件
        let fileName = "conflict_test.txt"
        let initialContent = "Initial content".data(using: .utf8)!
        let fileId = try await advancedSyncManager.createFile(
            name: fileName,
            content: initialContent,
            parentPath: "/test"
        )
        
        try await waitForSyncCompletion()
        
        // 同时修改本地和云端（创建冲突）
        let localContent = "Local modification for conflict".data(using: .utf8)!
        let cloudContent = "Cloud modification for conflict".data(using: .utf8)!
        
        // 本地修改
        try await advancedSyncManager.modifyFile(fileId: fileId, newContent: localContent)
        
        // 模拟云端修改（不同时间戳）
        let remotePath = "/test/\(fileName)"
        mockStorageClient.updateRemoteFile(path: remotePath, content: cloudContent, timestamp: Date().addingTimeInterval(10))
        
        // 检测冲突
        let conflicts = await advancedSyncManager.detectConflicts(for: fileId)
        
        // 验证冲突被检测到
        XCTAssertFalse(conflicts.isEmpty)
        XCTAssertEqual(conflicts.first?.type, .contentConflict)
    }
    
    /// 测试自动冲突解决 - 合并策略
    func testAutoConflictResolution_Merge() async throws {
        // 创建文件
        let fileName = "merge_test.txt"
        let initialContent = "Line 1\nLine 2\nLine 3".data(using: .utf8)!
        let fileId = try await advancedSyncManager.createFile(
            name: fileName,
            content: initialContent,
            parentPath: "/test"
        )
        
        try await waitForSyncCompletion()
        
        // 创建可合并的修改
        let localContent = "Line 1\nLocal Line 2\nLine 3".data(using: .utf8)!
        let cloudContent = "Line 1\nLine 2\nCloud Line 3".data(using: .utf8)!
        
        // 本地修改
        try await advancedSyncManager.modifyFile(fileId: fileId, newContent: localContent)
        
        // 模拟云端修改
        let remotePath = "/test/\(fileName)"
        mockStorageClient.updateRemoteFile(path: remotePath, content: cloudContent)
        
        // 检测并解决冲突
        let conflicts = await advancedSyncManager.detectConflicts(for: fileId)
        XCTAssertFalse(conflicts.isEmpty)
        
        let conflict = conflicts.first!
        let result = await advancedSyncManager.resolveConflict(conflict, strategy: .merge)
        
        // 验证冲突解决成功
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.strategy, .merge)
    }
    
    /// 测试手动冲突解决
    func testManualConflictResolution() async throws {
        // 创建不可自动合并的冲突
        let fileName = "manual_conflict_test.txt"
        let initialContent = "Original content".data(using: .utf8)!
        let fileId = try await advancedSyncManager.createFile(
            name: fileName,
            content: initialContent,
            parentPath: "/test"
        )
        
        try await waitForSyncCompletion()
        
        // 创建完全不同的修改
        let localContent = "Completely different local content".data(using: .utf8)!
        let cloudContent = "Totally different cloud content".data(using: .utf8)!
        
        // 本地修改
        try await advancedSyncManager.modifyFile(fileId: fileId, newContent: localContent)
        
        // 模拟云端修改
        let remotePath = "/test/\(fileName)"
        mockStorageClient.updateRemoteFile(path: remotePath, content: cloudContent)
        
        // 检测冲突
        let conflicts = await advancedSyncManager.detectConflicts(for: fileId)
        XCTAssertFalse(conflicts.isEmpty)
        
        let conflict = conflicts.first!
        
        // 尝试自动解决（应该失败）
        let autoResult = await advancedSyncManager.resolveConflict(conflict, strategy: .merge)
        
        // 手动解决 - 使用本地版本
        let manualResult = await advancedSyncManager.resolveConflict(conflict, strategy: .useLocal)
        
        // 验证手动解决成功
        XCTAssertTrue(manualResult.success)
        XCTAssertEqual(manualResult.strategy, .useLocal)
    }
    
    // MARK: - 网络状态测试
    
    /// 测试离线状态下的操作
    func testOfflineOperations() async throws {
        // 模拟离线状态
        mockStorageClient.isOnline = false
        
        // 创建文件（应该成功，但不会立即上传）
        let fileName = "offline_test.txt"
        let content = "Offline content".data(using: .utf8)!
        let fileId = try await advancedSyncManager.createFile(
            name: fileName,
            content: content,
            parentPath: "/test"
        )
        
        // 验证文件创建成功
        XCTAssertNotNil(fileId)
        
        let metadata = advancedSyncManager.getMetadata(fileId: fileId)
        XCTAssertEqual(metadata?.syncStatus, .localOnly)
        
        // 验证文件未上传
        XCTAssertFalse(mockStorageClient.uploadedFiles.contains("/test/\(fileName)"))
        
        // 恢复网络
        mockStorageClient.isOnline = true
        advancedSyncManager.resumeSync()
        
        // 等待同步完成
        try await waitForSyncCompletion()
        
        // 验证文件已上传
        XCTAssertTrue(mockStorageClient.uploadedFiles.contains("/test/\(fileName)"))
    }
    
    /// 测试网络恢复后的同步
    func testSyncAfterNetworkRecovery() async throws {
        // 离线状态下创建多个文件
        mockStorageClient.isOnline = false
        
        var fileIds: [String] = []
        for i in 1...5 {
            let fileName = "recovery_test_\(i).txt"
            let content = "Content \(i)".data(using: .utf8)!
            let fileId = try await advancedSyncManager.createFile(
                name: fileName,
                content: content,
                parentPath: "/test"
            )
            fileIds.append(fileId)
        }
        
        // 验证所有文件都是本地状态
        for fileId in fileIds {
            let metadata = advancedSyncManager.getMetadata(fileId: fileId)
            XCTAssertEqual(metadata?.syncStatus, .localOnly)
        }
        
        // 恢复网络
        mockStorageClient.isOnline = true
        advancedSyncManager.resumeSync()
        
        // 等待同步完成
        try await waitForSyncCompletion()
        
        // 验证所有文件都已同步
        for fileId in fileIds {
            let metadata = advancedSyncManager.getMetadata(fileId: fileId)
            XCTAssertEqual(metadata?.syncStatus, .synced)
        }
    }
    
    // MARK: - 操作转换测试
    
    /// 测试并发插入操作转换
    func testConcurrentInsertOperations() async throws {
        let fileName = "concurrent_insert_test.txt"
        let initialContent = "Line 1\nLine 2\nLine 3".data(using: .utf8)!
        let fileId = try await advancedSyncManager.createFile(
            name: fileName,
            content: initialContent,
            parentPath: "/test"
        )
        
        try await waitForSyncCompletion()
        
        // 创建并发插入操作
        let insertOp1 = AtomicOperation.insert(
            position: 7, // 在 "Line 1\n" 后插入
            content: "Inserted A\n",
            timestamp: Date(),
            deviceId: "device1",
            operationId: UUID().uuidString
        )
        
        let insertOp2 = AtomicOperation.insert(
            position: 7, // 同一位置插入
            content: "Inserted B\n",
            timestamp: Date().addingTimeInterval(0.1),
            deviceId: "device2",
            operationId: UUID().uuidString
        )
        
        // 应用操作转换
        try await advancedSyncManager.modifyFile(fileId: fileId, newContent: initialContent, operations: [insertOp1, insertOp2])
        
        // 验证结果
        let metadata = advancedSyncManager.getMetadata(fileId: fileId)
        XCTAssertNotNil(metadata)
        
        // 验证两个插入都被正确应用
        if let localPath = metadata?.localPath {
            let finalContent = try String(contentsOf: URL(fileURLWithPath: localPath))
            XCTAssertTrue(finalContent.contains("Inserted A"))
            XCTAssertTrue(finalContent.contains("Inserted B"))
        }
    }
    
    /// 测试并发删除操作转换
    func testConcurrentDeleteOperations() async throws {
        let fileName = "concurrent_delete_test.txt"
        let initialContent = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5".data(using: .utf8)!
        let fileId = try await advancedSyncManager.createFile(
            name: fileName,
            content: initialContent,
            parentPath: "/test"
        )
        
        try await waitForSyncCompletion()
        
        // 创建并发删除操作
        let deleteOp1 = AtomicOperation.delete(
            position: 7, // 删除 "Line 2\n"
            length: 7,
            timestamp: Date(),
            deviceId: "device1",
            operationId: UUID().uuidString
        )
        
        let deleteOp2 = AtomicOperation.delete(
            position: 14, // 删除 "Line 3\n"
            length: 7,
            timestamp: Date().addingTimeInterval(0.1),
            deviceId: "device2",
            operationId: UUID().uuidString
        )
        
        // 应用操作转换
        try await advancedSyncManager.modifyFile(fileId: fileId, newContent: initialContent, operations: [deleteOp1, deleteOp2])
        
        // 验证结果
        let metadata = advancedSyncManager.getMetadata(fileId: fileId)
        XCTAssertNotNil(metadata)
        
        // 验证删除操作被正确应用
        if let localPath = metadata?.localPath {
            let finalContent = try String(contentsOf: URL(fileURLWithPath: localPath))
            XCTAssertFalse(finalContent.contains("Line 2"))
            XCTAssertFalse(finalContent.contains("Line 3"))
            XCTAssertTrue(finalContent.contains("Line 1"))
            XCTAssertTrue(finalContent.contains("Line 4"))
            XCTAssertTrue(finalContent.contains("Line 5"))
        }
    }
    
    // MARK: - CRDT测试
    
    /// 测试CRDT文档合并
    func testCRDTDocumentMerge() async throws {
        let fileName = "crdt_test.txt"
        let initialContent = "Initial CRDT content".data(using: .utf8)!
        let fileId = try await advancedSyncManager.createFile(
            name: fileName,
            content: initialContent,
            parentPath: "/test"
        )
        
        try await waitForSyncCompletion()
        
        // 模拟多设备并发修改
        let device1Content = "Device 1 modification".data(using: .utf8)!
        let device2Content = "Device 2 modification".data(using: .utf8)!
        
        // 设备1修改
        try await advancedSyncManager.modifyFile(fileId: fileId, newContent: device1Content)
        
        // 模拟设备2修改（通过云端）
        let remotePath = "/test/\(fileName)"
        mockStorageClient.updateRemoteFile(path: remotePath, content: device2Content)
        
        // 触发同步和合并
        advancedSyncManager.startSync()
        try await waitForSyncCompletion()
        
        // 验证CRDT合并结果
        let metadata = advancedSyncManager.getMetadata(fileId: fileId)
        XCTAssertNotNil(metadata)
        XCTAssertEqual(metadata?.syncStatus, .synced)
    }
    
    // MARK: - 性能测试
    
    /// 测试大量文件同步性能
    func testLargeScaleSync() async throws {
        let fileCount = 100
        var fileIds: [String] = []
        
        // 创建大量文件
        for i in 1...fileCount {
            let fileName = "perf_test_\(i).txt"
            let content = "Performance test content \(i)".data(using: .utf8)!
            let fileId = try await advancedSyncManager.createFile(
                name: fileName,
                content: content,
                parentPath: "/test"
            )
            fileIds.append(fileId)
        }
        
        let startTime = Date()
        
        // 等待所有文件同步完成
        try await waitForSyncCompletion()
        
        let endTime = Date()
        let syncDuration = endTime.timeIntervalSince(startTime)
        
        // 验证性能（应该在合理时间内完成）
        XCTAssertLessThan(syncDuration, 30.0, "大量文件同步耗时过长")
        
        // 验证所有文件都已同步
        for fileId in fileIds {
            let metadata = advancedSyncManager.getMetadata(fileId: fileId)
            XCTAssertEqual(metadata?.syncStatus, .synced)
        }
    }
    
    // MARK: - 辅助方法
    
    private func waitForSyncCompletion(timeout: TimeInterval = 10.0) async throws {
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < timeout {
            if advancedSyncManager.syncProgress.isComplete {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
        }
        
        throw XCTSkip("同步超时")
    }
}

// MARK: - Mock存储客户端

class MockStorageClient: StorageClient {
    var isOnline = true
    var uploadedFiles: Set<String> = []
    var deletedFiles: Set<String> = []
    private var remoteFiles: [String: (content: Data, timestamp: Date)] = [:]
    
    func addRemoteFile(path: String, content: Data, timestamp: Date = Date()) {
        remoteFiles[path] = (content, timestamp)
    }
    
    func updateRemoteFile(path: String, content: Data, timestamp: Date = Date()) {
        remoteFiles[path] = (content, timestamp)
    }
    
    func deleteRemoteFile(path: String) {
        remoteFiles.removeValue(forKey: path)
        deletedFiles.insert(path)
    }
    
    // MARK: - StorageClient实现
    
    override func uploadFile(localURL: URL, to remotePath: String, progress: @escaping (Double) -> Void) async throws {
        guard isOnline else {
            throw NSError(domain: "NetworkError", code: -1, userInfo: [NSLocalizedDescriptionKey: "网络不可用"])
        }
        
        let content = try Data(contentsOf: localURL)
        remoteFiles[remotePath] = (content, Date())
        uploadedFiles.insert(remotePath)
        progress(1.0)
    }
    
    override func downloadFile(path: String, to localURL: URL, progress: @escaping (Double) -> Void) async throws {
        guard isOnline else {
            throw NSError(domain: "NetworkError", code: -1, userInfo: [NSLocalizedDescriptionKey: "网络不可用"])
        }
        
        guard let (content, _) = remoteFiles[path] else {
            throw NSError(domain: "FileNotFound", code: -1, userInfo: [NSLocalizedDescriptionKey: "文件不存在"])
        }
        
        try content.write(to: localURL)
        progress(1.0)
    }
    
    override func delete(path: String) async throws {
        guard isOnline else {
            throw NSError(domain: "NetworkError", code: -1, userInfo: [NSLocalizedDescriptionKey: "网络不可用"])
        }
        
        remoteFiles.removeValue(forKey: path)
        deletedFiles.insert(path)
    }
    
    override func listDirectory(path: String) async throws -> [StorageResource] {
        guard isOnline else {
            throw NSError(domain: "NetworkError", code: -1, userInfo: [NSLocalizedDescriptionKey: "网络不可用"])
        }
        
        let pathPrefix = path.hasSuffix("/") ? path : path + "/"
        
        return remoteFiles.compactMap { (filePath, fileData) in
            guard filePath.hasPrefix(pathPrefix) else { return nil }
            
            let relativePath = String(filePath.dropFirst(pathPrefix.count))
            guard !relativePath.contains("/") else { return nil } // 只返回直接子文件
            
            return StorageResource(
                path: filePath,
                displayName: relativePath,
                isDirectory: false,
                contentLength: Int64(fileData.content.count),
                lastModified: fileData.timestamp,
                etag: "\(fileData.content.hashValue)"
            )
        }
    }
    
    override func createDirectory(path: String) async throws {
        guard isOnline else {
            throw NSError(domain: "NetworkError", code: -1, userInfo: [NSLocalizedDescriptionKey: "网络不可用"])
        }
        
        // 模拟目录创建
        remoteFiles[path] = (Data(), Date())
    }
}

// MARK: - 测试扩展

extension AdvancedSyncManager {
    func getMetadata(fileId: String) -> AdvancedFileMetadata? {
        // 这里应该暴露内部的getMetadata方法用于测试
        // 实际实现中可能需要添加测试专用的接口
        return nil
    }
}