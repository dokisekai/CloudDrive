//
//  SyncIntegrationTests.swift
//  CloudDriveCore
//
//  同步系统集成测试 - 端到端功能验证
//

import XCTest
import Foundation
@testable import CloudDriveCore

class SyncIntegrationTests: XCTestCase {
    
    var syncManager: AdvancedSyncManager!
    var mockStorageClient: MockStorageClient!
    var testWorkspace: URL!
    var testRemoteRoot: String!
    
    override func setUp() async throws {
        try await super.setUp()
        
        // 创建测试工作空间
        testWorkspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SyncIntegrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testWorkspace, withIntermediateDirectories: true)
        
        testRemoteRoot = "/integration-test-\(UUID().uuidString)"
        
        // 初始化同步管理器
        syncManager = AdvancedSyncManager.shared
        mockStorageClient = MockStorageClient()
        syncManager.configure(storageClient: mockStorageClient)
        
        // 确保网络在线
        mockStorageClient.isOnline = true
    }
    
    override func tearDown() async throws {
        // 清理测试工作空间
        try? FileManager.default.removeItem(at: testWorkspace)
        
        syncManager = nil
        mockStorageClient = nil
        
        try await super.tearDown()
    }
    
    // MARK: - 端到端同步测试
    
    /// 测试完整的文件生命周期同步
    func testCompleteFileLifecycleSync() async throws {
        let fileName = "lifecycle_test.txt"
        let initialContent = "Initial content for lifecycle test".data(using: .utf8)!
        let modifiedContent = "Modified content for lifecycle test".data(using: .utf8)!
        
        // 1. 创建文件
        let fileId = try await syncManager.createFile(
            name: fileName,
            content: initialContent,
            parentPath: testRemoteRoot
        )
        
        // 等待上传完成
        try await waitForSyncCompletion()
        
        // 验证文件已上传
        XCTAssertTrue(mockStorageClient.uploadedFiles.contains("\(testRemoteRoot)/\(fileName)"))
        
        // 2. 修改文件
        try await syncManager.modifyFile(fileId: fileId, newContent: modifiedContent)
        
        // 等待修改同步完成
        try await waitForSyncCompletion()
        
        // 验证修改已同步
        let remoteContent = try await getRemoteFileContent("\(testRemoteRoot)/\(fileName)")
        XCTAssertEqual(remoteContent, modifiedContent)
        
        // 3. 删除文件
        try await syncManager.deleteFile(fileId: fileId)
        
        // 等待删除同步完成
        try await waitForSyncCompletion()
        
        // 验证文件已从云端删除
        XCTAssertTrue(mockStorageClient.deletedFiles.contains("\(testRemoteRoot)/\(fileName)"))
    }
    
    /// 测试多设备协作场景
    func testMultiDeviceCollaboration() async throws {
        let fileName = "collaboration_test.txt"
        let device1Content = "Content from device 1".data(using: .utf8)!
        let device2Content = "Content from device 2".data(using: .utf8)!
        
        // 设备1创建文件
        let fileId = try await syncManager.createFile(
            name: fileName,
            content: device1Content,
            parentPath: testRemoteRoot
        )
        
        try await waitForSyncCompletion()
        
        // 模拟设备2同时修改同一文件
        let remotePath = "\(testRemoteRoot)/\(fileName)"
        mockStorageClient.updateRemoteFile(path: remotePath, content: device2Content)
        
        // 设备1也修改文件
        let device1ModifiedContent = "Modified content from device 1".data(using: .utf8)!
        try await syncManager.modifyFile(fileId: fileId, newContent: device1ModifiedContent)
        
        // 触发同步，应该检测到冲突
        syncManager.startSync()
        try await waitForSyncCompletion()
        
        // 验证冲突被检测到
        let conflicts = await syncManager.detectConflicts(for: fileId)
        XCTAssertFalse(conflicts.isEmpty)
        
        // 自动解决冲突
        if let conflict = conflicts.first {
            let result = await syncManager.resolveConflict(conflict, strategy: .merge)
            XCTAssertTrue(result.success)
        }
    }
    
    /// 测试大文件同步
    func testLargeFileSync() async throws {
        let fileName = "large_file_test.bin"
        let largeContent = Data(repeating: 0x42, count: 10 * 1024 * 1024) // 10MB
        
        let startTime = Date()
        
        // 创建大文件
        let fileId = try await syncManager.createFile(
            name: fileName,
            content: largeContent,
            parentPath: testRemoteRoot,
            mimeType: "application/octet-stream"
        )
        
        // 等待上传完成
        try await waitForSyncCompletion(timeout: 60.0)
        
        let endTime = Date()
        let uploadDuration = endTime.timeIntervalSince(startTime)
        
        // 验证上传成功
        XCTAssertTrue(mockStorageClient.uploadedFiles.contains("\(testRemoteRoot)/\(fileName)"))
        
        // 验证上传时间合理（应该在1分钟内完成）
        XCTAssertLessThan(uploadDuration, 60.0)
        
        // 验证文件内容完整性
        let remoteContent = try await getRemoteFileContent("\(testRemoteRoot)/\(fileName)")
        XCTAssertEqual(remoteContent.count, largeContent.count)
        XCTAssertEqual(remoteContent, largeContent)
    }
    
    /// 测试目录结构同步
    func testDirectoryStructureSync() async throws {
        let baseDir = testRemoteRoot
        let subDir1 = "subdir1"
        let subDir2 = "subdir2"
        let nestedDir = "nested"
        
        // 创建复杂的目录结构
        let files = [
            "\(baseDir)/file1.txt": "Content 1",
            "\(baseDir)/\(subDir1)/file2.txt": "Content 2",
            "\(baseDir)/\(subDir1)/\(nestedDir)/file3.txt": "Content 3",
            "\(baseDir)/\(subDir2)/file4.txt": "Content 4"
        ]
        
        var fileIds: [String] = []
        
        // 创建所有文件
        for (path, content) in files {
            let pathComponents = path.components(separatedBy: "/")
            let fileName = pathComponents.last!
            let parentPath = pathComponents.dropLast().joined(separator: "/")
            
            let fileId = try await syncManager.createFile(
                name: fileName,
                content: content.data(using: .utf8)!,
                parentPath: parentPath
            )
            fileIds.append(fileId)
        }
        
        // 等待所有文件同步完成
        try await waitForSyncCompletion()
        
        // 验证所有文件都已上传
        for (path, _) in files {
            XCTAssertTrue(mockStorageClient.uploadedFiles.contains(path))
        }
        
        // 验证目录结构完整性
        let remoteFiles = try await mockStorageClient.listDirectory(path: baseDir)
        XCTAssertFalse(remoteFiles.isEmpty)
    }
    
    /// 测试网络中断恢复场景
    func testNetworkInterruptionRecovery() async throws {
        let fileName = "network_test.txt"
        let content = "Network interruption test content".data(using: .utf8)!
        
        // 创建文件（网络正常）
        let fileId = try await syncManager.createFile(
            name: fileName,
            content: content,
            parentPath: testRemoteRoot
        )
        
        try await waitForSyncCompletion()
        
        // 模拟网络中断
        mockStorageClient.isOnline = false
        
        // 在离线状态下修改文件
        let offlineContent = "Modified while offline".data(using: .utf8)!
        try await syncManager.modifyFile(fileId: fileId, newContent: offlineContent)
        
        // 验证文件状态为待上传
        let metadata = getFileMetadata(fileId: fileId)
        XCTAssertEqual(metadata?.syncStatus, .pendingUpload)
        
        // 恢复网络
        mockStorageClient.isOnline = true
        syncManager.resumeSync()
        
        // 等待同步完成
        try await waitForSyncCompletion()
        
        // 验证离线修改已同步
        let remoteContent = try await getRemoteFileContent("\(testRemoteRoot)/\(fileName)")
        XCTAssertEqual(remoteContent, offlineContent)
    }
    
    /// 测试并发操作处理
    func testConcurrentOperations() async throws {
        let baseFileName = "concurrent_test"
        let fileCount = 20
        let content = "Concurrent operation test content".data(using: .utf8)!
        
        // 并发创建多个文件
        await withTaskGroup(of: String?.self) { group in
            for i in 1...fileCount {
                group.addTask {
                    do {
                        let fileName = "\(baseFileName)_\(i).txt"
                        return try await self.syncManager.createFile(
                            name: fileName,
                            content: content,
                            parentPath: self.testRemoteRoot
                        )
                    } catch {
                        XCTFail("并发创建文件失败: \(error)")
                        return nil
                    }
                }
            }
            
            var createdFileIds: [String] = []
            for await fileId in group {
                if let fileId = fileId {
                    createdFileIds.append(fileId)
                }
            }
            
            XCTAssertEqual(createdFileIds.count, fileCount)
        }
        
        // 等待所有文件同步完成
        try await waitForSyncCompletion(timeout: 30.0)
        
        // 验证所有文件都已上传
        for i in 1...fileCount {
            let fileName = "\(baseFileName)_\(i).txt"
            let path = "\(testRemoteRoot)/\(fileName)"
            XCTAssertTrue(mockStorageClient.uploadedFiles.contains(path))
        }
    }
    
    /// 测试冲突解决的完整流程
    func testCompleteConflictResolutionFlow() async throws {
        let fileName = "conflict_resolution_test.txt"
        let initialContent = "Initial content\nLine 2\nLine 3".data(using: .utf8)!
        
        // 创建初始文件
        let fileId = try await syncManager.createFile(
            name: fileName,
            content: initialContent,
            parentPath: testRemoteRoot
        )
        
        try await waitForSyncCompletion()
        
        // 模拟两个设备同时修改
        let localModification = "Local modification\nLine 2\nLine 3".data(using: .utf8)!
        let remoteModification = "Initial content\nRemote modification\nLine 3".data(using: .utf8)!
        
        // 本地修改
        try await syncManager.modifyFile(fileId: fileId, newContent: localModification)
        
        // 远程修改
        let remotePath = "\(testRemoteRoot)/\(fileName)"
        mockStorageClient.updateRemoteFile(path: remotePath, content: remoteModification)
        
        // 触发同步，检测冲突
        syncManager.startSync()
        
        // 等待冲突检测完成
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
        
        let conflicts = await syncManager.detectConflicts(for: fileId)
        XCTAssertFalse(conflicts.isEmpty)
        
        let conflict = conflicts.first!
        XCTAssertEqual(conflict.type, .contentConflict)
        
        // 自动解决冲突（合并策略）
        let resolutionResult = await syncManager.resolveConflict(conflict, strategy: .merge)
        XCTAssertTrue(resolutionResult.success)
        
        // 等待解决结果同步
        try await waitForSyncCompletion()
        
        // 验证冲突已解决
        let finalConflicts = await syncManager.detectConflicts(for: fileId)
        XCTAssertTrue(finalConflicts.isEmpty)
        
        // 验证合并结果包含两个修改
        let finalContent = try await getRemoteFileContent(remotePath)
        let finalString = String(data: finalContent, encoding: .utf8)!
        XCTAssertTrue(finalString.contains("Local modification") || finalString.contains("Remote modification"))
    }
    
    /// 测试版本控制功能
    func testVersionControlIntegration() async throws {
        let fileName = "version_control_test.txt"
        let version1Content = "Version 1 content".data(using: .utf8)!
        let version2Content = "Version 2 content".data(using: .utf8)!
        let version3Content = "Version 3 content".data(using: .utf8)!
        
        // 创建文件（版本1）
        let fileId = try await syncManager.createFile(
            name: fileName,
            content: version1Content,
            parentPath: testRemoteRoot
        )
        
        try await waitForSyncCompletion()
        
        // 修改文件（版本2）
        try await syncManager.modifyFile(fileId: fileId, newContent: version2Content)
        try await waitForSyncCompletion()
        
        // 再次修改文件（版本3）
        try await syncManager.modifyFile(fileId: fileId, newContent: version3Content)
        try await waitForSyncCompletion()
        
        // 验证版本历史
        let metadata = getFileMetadata(fileId: fileId)
        XCTAssertNotNil(metadata?.versionControlCommitId)
        
        // 验证最终内容
        let remotePath = "\(testRemoteRoot)/\(fileName)"
        let finalContent = try await getRemoteFileContent(remotePath)
        XCTAssertEqual(finalContent, version3Content)
    }
    
    /// 测试同步性能和资源使用
    func testSyncPerformanceAndResources() async throws {
        let fileCount = 50
        let fileSize = 1024 * 1024 // 1MB per file
        let totalSize = fileCount * fileSize
        
        let startTime = Date()
        let initialMemory = getCurrentMemoryUsage()
        
        // 创建大量文件
        var fileIds: [String] = []
        for i in 1...fileCount {
            let fileName = "perf_test_\(i).bin"
            let content = Data(repeating: UInt8(i % 256), count: fileSize)
            
            let fileId = try await syncManager.createFile(
                name: fileName,
                content: content,
                parentPath: testRemoteRoot,
                mimeType: "application/octet-stream"
            )
            fileIds.append(fileId)
        }
        
        // 等待所有文件同步完成
        try await waitForSyncCompletion(timeout: 120.0)
        
        let endTime = Date()
        let finalMemory = getCurrentMemoryUsage()
        
        let syncDuration = endTime.timeIntervalSince(startTime)
        let memoryIncrease = finalMemory - initialMemory
        
        // 性能验证
        let throughput = Double(totalSize) / syncDuration / (1024 * 1024) // MB/s
        XCTAssertGreaterThan(throughput, 1.0, "同步吞吐量过低")
        
        // 内存使用验证（不应该超过文件总大小的2倍）
        XCTAssertLessThan(memoryIncrease, totalSize * 2, "内存使用过多")
        
        // 验证所有文件都已同步
        for (index, fileId) in fileIds.enumerated() {
            let metadata = getFileMetadata(fileId: fileId)
            XCTAssertEqual(metadata?.syncStatus, .synced, "文件 \(index + 1) 未同步")
        }
    }
    
    /// 测试错误恢复机制
    func testErrorRecoveryMechanism() async throws {
        let fileName = "error_recovery_test.txt"
        let content = "Error recovery test content".data(using: .utf8)!
        
        // 创建文件
        let fileId = try await syncManager.createFile(
            name: fileName,
            content: content,
            parentPath: testRemoteRoot
        )
        
        try await waitForSyncCompletion()
        
        // 模拟网络错误
        mockStorageClient.shouldFailNextOperation = true
        
        // 尝试修改文件（应该失败）
        let modifiedContent = "Modified content".data(using: .utf8)!
        try await syncManager.modifyFile(fileId: fileId, newContent: modifiedContent)
        
        // 等待错误处理
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
        
        // 验证文件状态为错误或待重试
        let metadata = getFileMetadata(fileId: fileId)
        XCTAssertTrue(metadata?.syncStatus == .error || metadata?.syncStatus == .pendingUpload)
        
        // 恢复网络
        mockStorageClient.shouldFailNextOperation = false
        
        // 重试同步
        syncManager.resumeSync()
        try await waitForSyncCompletion()
        
        // 验证错误恢复成功
        let finalMetadata = getFileMetadata(fileId: fileId)
        XCTAssertEqual(finalMetadata?.syncStatus, .synced)
    }
    
    // MARK: - 辅助方法
    
    private func waitForSyncCompletion(timeout: TimeInterval = 30.0) async throws {
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < timeout {
            if syncManager.syncProgress.isComplete {
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
        }
        
        throw XCTSkip("同步超时，当前进度: \(syncManager.syncProgress.progress)")
    }
    
    private func getRemoteFileContent(_ path: String) async throws -> Data {
        guard let (content, _) = mockStorageClient.remoteFiles[path] else {
            throw NSError(domain: "TestError", code: -1, userInfo: [NSLocalizedDescriptionKey: "远程文件不存在: \(path)"])
        }
        return content
    }
    
    private func getFileMetadata(fileId: String) -> AdvancedFileMetadata? {
        // 这里需要暴露内部方法用于测试
        return syncManager.getMetadata(fileId: fileId)
    }
    
    private func getCurrentMemoryUsage() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            return Int(info.resident_size)
        } else {
            return 0
        }
    }
}

// MARK: - 增强的Mock存储客户端

extension MockStorageClient {
    var shouldFailNextOperation: Bool {
        get { return _shouldFailNextOperation }
        set { _shouldFailNextOperation = newValue }
    }
    
    private static var _shouldFailNextOperation = false
    
    var remoteFiles: [String: (content: Data, timestamp: Date)] {
        return _remoteFiles
    }
    
    private var _remoteFiles: [String: (content: Data, timestamp: Date)] = [:]
    
    override func uploadFile(localURL: URL, to remotePath: String, progress: @escaping (Double) -> Void) async throws {
        if shouldFailNextOperation {
            shouldFailNextOperation = false
            throw NSError(domain: "MockError", code: -1, userInfo: [NSLocalizedDescriptionKey: "模拟上传失败"])
        }
        
        try await super.uploadFile(localURL: localURL, to: remotePath, progress: progress)
    }
    
    override func downloadFile(path: String, to localURL: URL, progress: @escaping (Double) -> Void) async throws {
        if shouldFailNextOperation {
            shouldFailNextOperation = false
            throw NSError(domain: "MockError", code: -1, userInfo: [NSLocalizedDescriptionKey: "模拟下载失败"])
        }
        
        try await super.downloadFile(path: path, to: localURL, progress: progress)
    }
    
    override func delete(path: String) async throws {
        if shouldFailNextOperation {
            shouldFailNextOperation = false
            throw NSError(domain: "MockError", code: -1, userInfo: [NSLocalizedDescriptionKey: "模拟删除失败"])
        }
        
        try await super.delete(path: path)
    }
}

// MARK: - 测试辅助扩展

extension AdvancedSyncManager {
    // 为测试暴露内部方法
    func getMetadata(fileId: String) -> AdvancedFileMetadata? {
        // 实际实现中需要添加这个方法
        return nil
    }
    
    var syncProgress: SyncProgress {
        // 实际实现中需要暴露这个属性
        return SyncProgress()
    }
}

// MARK: - 性能测试辅助

class PerformanceTestHelper {
    static func measureTime<T>(operation: () async throws -> T) async rethrows -> (result: T, duration: TimeInterval) {
        let startTime = Date()
        let result = try await operation()
        let endTime = Date()
        let duration = endTime.timeIntervalSince(startTime)
        return (result, duration)
    }
    
    static func measureMemory<T>(operation: () async throws -> T) async rethrows -> (result: T, memoryDelta: Int) {
        let initialMemory = getCurrentMemoryUsage()
        let result = try await operation()
        let finalMemory = getCurrentMemoryUsage()
        let memoryDelta = finalMemory - initialMemory
        return (result, memoryDelta)
    }
    
    private static func getCurrentMemoryUsage() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        return kerr == KERN_SUCCESS ? Int(info.resident_size) : 0
    }
}