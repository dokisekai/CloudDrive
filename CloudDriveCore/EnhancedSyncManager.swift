//
//  EnhancedSyncManager.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  增强同步管理器 - 双向自动同步 + 增量同步
//

import Foundation

/// 增强同步管理器
public class EnhancedSyncManager {
    public static let shared = EnhancedSyncManager()
    
    private let syncManager = SyncManager.shared
    private let fileMonitor = FileMonitor.shared
    private let cacheManager = CacheManager.shared
    
    // 同步状态
    private var syncTasks: [String: Task<Void, Never>] = [:]
    private let syncTasksQueue = DispatchQueue(label: "com.clouddrive.enhancedsync.tasks")
    private let syncQueue = DispatchQueue(label: "com.clouddrive.enhancedsync")
    
    // 是否正在运行
    private var isRunning = false
    private let stateLock = NSLock()
    
    // 自动同步配置
    public var autoSyncEnabled: Bool = true
    public var autoSyncDelay: TimeInterval = 2.0 // 变更后2秒开始同步
    public var conflictResolutionPolicy: ConflictResolutionPolicy = .localWins
    
    // 同步统计
    private var _syncStatistics = SyncStatistics()
    private let statsQueue = DispatchQueue(label: "com.clouddrive.enhancedsync.stats")
    
    public func getSyncStatistics() -> SyncStatistics {
        return statsQueue.sync { _syncStatistics }
    }
    
    public func resetStatistics() {
        statsQueue.sync { _syncStatistics = SyncStatistics() }
        Logger.shared.info(.sync, "同步统计已重置")
    }
    
    private init() {
        setupFileMonitor()
        Logger.shared.info(.sync, "增强同步管理器已初始化")
    }
    
    // MARK: - 启动/停止
    
    /// 启动增强同步
    public func start() {
        stateLock.lock()
        defer { stateLock.unlock() }
        
        guard !isRunning else {
            Logger.shared.warning(.sync, "增强同步已在运行")
            return
        }
        
        isRunning = true
        Logger.shared.success(.sync, "启动增强同步")
        
        // 启动文件监控
        fileMonitor.startMonitoring()
        
        // 启动后台同步任务
        startBackgroundSync()
        
        // 记录启动时间
        statsQueue.sync { _syncStatistics.lastStartTime = Date() }
    }
    
    /// 停止增强同步
    public func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        
        guard isRunning else {
            Logger.shared.warning(.sync, "增强同步未在运行")
            return
        }
        
        isRunning = false
        Logger.shared.info(.sync, "停止增强同步")
        
        // 停止文件监控
        fileMonitor.stopMonitoring()
        
        // 取消所有同步任务
        cancelAllSyncTasks()
        
        // 记录停止时间
        statsQueue.sync { _syncStatistics.lastStopTime = Date() }
    }
    
    // MARK: - 文件监控设置
    
    private func setupFileMonitor() {
        // 设置文件变更回调
        fileMonitor.onChange = { [weak self] event in
            guard let self = self, self.isRunning, self.autoSyncEnabled else {
                return
            }
            
            Logger.shared.info(.sync, "收到文件变更事件: \(event.description)")
            
            // 延迟处理，避免频繁同步
            let delay = self.autoSyncDelay
            
            // 取消之前的同步任务（如果存在）
            let existingTask = self.syncTasksQueue.sync { self.syncTasks[event.path] }
            if let existingTask = existingTask {
                existingTask.cancel()
                Logger.shared.info(.sync, "取消之前的同步任务: \(event.path)")
            }
            
            // 创建新的同步任务
            let task = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                
                if !Task.isCancelled {
                    Logger.shared.info(.sync, "开始同步文件: \(event.path)")
                    await self.handleFileChange(event: event)
                } else {
                    Logger.shared.info(.sync, "同步任务已取消: \(event.path)")
                }
            }
            
            self.syncTasksQueue.sync {
                self.syncTasks[event.path] = task
            }
        }
    }
    
    // MARK: - 同步处理
    
    /// 处理文件变更
    private func handleFileChange(event: FileChangeEvent) async {
        Logger.shared.info(.sync, "处理文件变更: \(event.description)")
        
        do {
            switch event.type {
            case .fileCreated, .fileModified:
                await syncFile(path: event.path, isLocal: event.isLocal)
                
            case .fileDeleted:
                await handleFileDeletion(path: event.path, isLocal: event.isLocal)
                
            case .directoryCreated:
                await syncDirectory(path: event.path, isLocal: event.isLocal)
                
            case .directoryModified:
                // 目录变化，重新同步目录内容
                await syncDirectoryContents(path: event.path)
                
            case .directoryDeleted:
                await handleDirectoryDeletion(path: event.path, isLocal: event.isLocal)
            }
            
            // 更新统计
            statsQueue.sync {
                _syncStatistics.totalSyncOperations += 1
                _syncStatistics.lastSyncTime = Date()
            }
            
        } catch {
            Logger.shared.error(.sync, "处理文件变更失败: \(event.path) - \(error)")
            statsQueue.sync { _syncStatistics.syncErrors += 1 }
        }
    }
    
    /// 同步文件
    private func syncFile(path: String, isLocal: Bool) async throws {
        let fileId = path
        
        Logger.shared.info(.sync, "开始同步文件: \(fileId) (来源: \(isLocal ? "本地" : "云端"))")
        
        guard let storageClient = syncManager.getStorageClient() else {
            throw SyncError.storageNotConfigured
        }
        
        if isLocal {
            // 本地 -> 云端
            Logger.shared.info(.sync, "上传本地文件到云端: \(fileId)")
            
            let localURL = URL(fileURLWithPath: path)
            
            // 检查本地文件是否存在
            guard FileManager.default.fileExists(atPath: path) else {
                Logger.shared.warning(.sync, "本地文件不存在: \(path)")
                throw SyncError.operationFailed("本地文件不存在")
            }
            
            let remotePath = path
            
            // 直接上传（不再重复加入队列）
            try await performUpload(fileId: fileId, localPath: path, remotePath: remotePath, storageClient: storageClient)
            
            Logger.shared.success(.sync, "文件上传成功: \(fileId)")
            
        } else {
            // 云端 -> 本地
            Logger.shared.info(.sync, "下载云端文件到本地: \(fileId)")
            
            // 检查本地是否存在
            let localURL = cacheManager.localPath(for: fileId)
            let localExists = FileManager.default.fileExists(atPath: localURL.path)
            
            if localExists {
                // 检查是否有冲突
                if await checkConflict(fileId: fileId) {
                    Logger.shared.warning(.sync, "检测到文件冲突: \(fileId)")
                    await resolveConflict(fileId: fileId)
                } else {
                    // 无冲突，覆盖本地
                    Logger.shared.info(.sync, "覆盖本地文件: \(fileId)")
                    try await performDownload(fileId: fileId, remotePath: path, storageClient: storageClient)
                }
            } else {
                // 直接下载
                Logger.shared.info(.sync, "下载新文件: \(fileId)")
                try await performDownload(fileId: fileId, remotePath: path, storageClient: storageClient)
            }
            
            Logger.shared.success(.sync, "文件下载成功: \(fileId)")
        }
    }
    
    /// 处理文件删除
    private func handleFileDeletion(path: String, isLocal: Bool) async {
        Logger.shared.info(.sync, "处理文件删除: \(path) (来源: \(isLocal ? "本地" : "云端"))")
        
        if isLocal {
            // 本地删除 -> 删除云端
            Logger.shared.info(.sync, "同步本地删除到云端: \(path)")
            
            // 直接执行删除，不再入队
            guard let storageClient = syncManager.getStorageClient() else {
                Logger.shared.warning(.sync, "存储客户端未配置，加入队列等待")
                syncManager.addToSyncQueue(.delete(fileId: path, remotePath: path))
                return
            }
            
            do {
                try await storageClient.delete(path: path)
                syncManager.removeMetadata(fileId: path)
                Logger.shared.success(.sync, "云端删除成功: \(path)")
            } catch {
                Logger.shared.error(.sync, "云端删除失败，加入队列重试: \(path) - \(error)")
                syncManager.addToSyncQueue(.delete(fileId: path, remotePath: path))
            }
            
        } else {
            // 云端删除 -> 删除本地
            Logger.shared.info(.sync, "同步云端删除到本地: \(path)")
            
            // 清理本地缓存
            try? cacheManager.removeCachedFile(fileId: path)
            
            // 删除元数据
            syncManager.removeMetadata(fileId: path)
        }
    }
    
    /// 同步目录
    private func syncDirectory(path: String, isLocal: Bool) async {
        Logger.shared.info(.sync, "同步目录: \(path) (来源: \(isLocal ? "本地" : "云端"))")
        
        if isLocal {
            // 本地目录 -> 云端
            do {
                guard let storageClient = syncManager.getStorageClient() else {
                    throw SyncError.storageNotConfigured
                }
                
                try await storageClient.createDirectory(path: path)
                Logger.shared.success(.sync, "目录创建成功: \(path)")
            } catch {
                Logger.shared.error(.sync, "创建目录失败: \(path) - \(error)")
            }
        } else {
            // 云端目录 -> 本地
            let localURL = cacheManager.localPath(for: path)
            
            // 确保本地目录存在
            if !FileManager.default.fileExists(atPath: localURL.path) {
                try? FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
            }
            
            Logger.shared.success(.sync, "本地目录就绪: \(path)")
        }
    }
    
    /// 同步目录内容
    private func syncDirectoryContents(path: String) async {
        Logger.shared.info(.sync, "同步目录内容: \(path)")
        
        do {
            // 调用基础同步管理器的目录同步
            let syncedFiles = try await syncManager.syncDirectory(
                directoryId: path,
                localPath: cacheManager.localPath(for: path).path,
                remotePath: path
            )
            
            Logger.shared.success(.sync, "目录内容同步完成: \(syncedFiles.count) 个文件")
            
        } catch {
            Logger.shared.error(.sync, "同步目录内容失败: \(path) - \(error)")
        }
    }
    
    /// 处理目录删除
    private func handleDirectoryDeletion(path: String, isLocal: Bool) async {
        Logger.shared.info(.sync, "处理目录删除: \(path)")
        
        if isLocal {
            // 本地删除 -> 删除云端
            // 递归删除云端内容
            // TODO: 实现递归删除
            Logger.shared.info(.sync, "同步本地目录删除到云端: \(path)")
        } else {
            // 云端删除 -> 删除本地
            Logger.shared.info(.sync, "同步云端目录删除到本地: \(path)")
            
            // 清理本地目录
            let localURL = cacheManager.localPath(for: path)
            try? FileManager.default.removeItem(at: localURL)
        }
    }
    
    // MARK: - 同步操作
    
    /// 执行上传
    private func performUpload(fileId: String, localPath: String, remotePath: String, storageClient: StorageClient) async throws {
        let localURL = URL(fileURLWithPath: localPath)
        
        try await storageClient.uploadFile(localURL: localURL, to: remotePath) { progress in
            Logger.shared.info(.sync, "上传进度: \(Int(progress * 100))%")
        }
        
        // 更新元数据
        if var metadata = syncManager.getMetadata(fileId: fileId) {
            metadata.syncStatus = .synced
            metadata.remotePath = remotePath
            metadata.remoteModifiedAt = Date()
            metadata.lastSyncTime = Date()
            syncManager.updateMetadata(metadata)
        }
    }
    
    /// 执行下载
    private func performDownload(fileId: String, remotePath: String, storageClient: StorageClient) async throws {
        let localURL = cacheManager.localPath(for: fileId)
        
        // 确保父目录存在
        let parentDir = localURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        
        // 下载到临时文件
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        
        try await storageClient.downloadFile(path: remotePath, to: tempURL) { progress in
            Logger.shared.info(.sync, "下载进度: \(Int(progress * 100))%")
        }
        
        // 移动到缓存
        try cacheManager.cacheFile(fileId: fileId, from: tempURL, policy: .automatic)
        
        // 更新元数据
        if var metadata = syncManager.getMetadata(fileId: fileId) {
            metadata.syncStatus = .synced
            metadata.localPath = localURL.path
            metadata.localModifiedAt = Date()
            metadata.lastSyncTime = Date()
            syncManager.updateMetadata(metadata)
        }
    }
    
    // MARK: - 冲突检测与解决
    
    /// 检查文件冲突
    private func checkConflict(fileId: String) async -> Bool {
        guard let metadata = syncManager.getMetadata(fileId: fileId) else {
            return false
        }
        return metadata.hasSyncConflict
    }
    
    /// 解决文件冲突
    private func resolveConflict(fileId: String) async {
        Logger.shared.info(.sync, "解决文件冲突: \(fileId)")
        
        switch conflictResolutionPolicy {
        case .localWins:
            Logger.shared.info(.sync, "冲突解决策略: 本地优先")
            // 保留本地，上传到云端
            if let metadata = syncManager.getMetadata(fileId: fileId),
               let localPath = metadata.localPath,
               let storageClient = syncManager.getStorageClient() {
                try? await performUpload(
                    fileId: fileId,
                    localPath: localPath,
                    remotePath: fileId,
                    storageClient: storageClient
                )
            }
            
        case .remoteWins:
            Logger.shared.info(.sync, "冲突解决策略: 云端优先")
            // 保留云端，下载到本地
            if let storageClient = syncManager.getStorageClient() {
                try? await performDownload(
                    fileId: fileId,
                    remotePath: fileId,
                    storageClient: storageClient
                )
            }
            
        case .renameLocal:
            Logger.shared.info(.sync, "冲突解决策略: 重命名本地文件")
            // 重命名本地文件
            await renameLocalFile(fileId: fileId)
            
        case .askUser:
            Logger.shared.info(.sync, "冲突解决策略: 询问用户")
            // TODO: 实现用户交互
            Logger.shared.warning(.sync, "用户交互冲突解决尚未实现，默认使用本地优先")
            // 暂时使用本地优先
            if let metadata = syncManager.getMetadata(fileId: fileId),
               let localPath = metadata.localPath,
               let storageClient = syncManager.getStorageClient() {
                try? await performUpload(
                    fileId: fileId,
                    localPath: localPath,
                    remotePath: fileId,
                    storageClient: storageClient
                )
            }
        }
    }
    
    /// 重命名本地文件
    private func renameLocalFile(fileId: String) async {
        guard let metadata = syncManager.getMetadata(fileId: fileId),
              let localPath = metadata.localPath else {
            return
        }
        
        let fileURL = URL(fileURLWithPath: localPath)
        let fileName = fileURL.lastPathComponent
        let fileExt = fileURL.pathExtension
        
        // 添加冲突标记
        let timestamp = Int(Date().timeIntervalSince1970)
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let newName: String
        if fileExt.isEmpty {
            newName = "\(baseName)_conflict_\(timestamp)"
        } else {
            newName = "\(baseName)_conflict_\(timestamp).\(fileExt)"
        }
        let newURL = fileURL.deletingLastPathComponent().appendingPathComponent(newName)
        
        do {
            try FileManager.default.moveItem(at: fileURL, to: newURL)
            Logger.shared.success(.sync, "本地文件已重命名: \(newName)")
            
            // 下载云端版本
            if let storageClient = syncManager.getStorageClient() {
                try? await performDownload(
                    fileId: fileId,
                    remotePath: fileId,
                    storageClient: storageClient
                )
            }
        } catch {
            Logger.shared.error(.sync, "重命名文件失败: \(error)")
        }
    }
    
    // MARK: - 后台同步
    
    // 后台同步定时器
    private var backgroundSyncTimer: DispatchSourceTimer?
    
    /// 启动后台同步
    private func startBackgroundSync() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + 60, repeating: 300)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isRunning else { return }
            
            Task {
                await self.performBackgroundSync()
            }
        }
        timer.resume()
        self.backgroundSyncTimer = timer
    }
    
    /// 执行后台同步
    private func performBackgroundSync() async {
        Logger.shared.info(.sync, "执行后台同步...")
        
        // 触发云端检查
        await fileMonitor.triggerCloudSyncCheck()
        
        // 处理同步队列
        syncManager.processSyncQueue()
    }
    
    // MARK: - 任务管理
    
    /// 取消所有同步任务
    private func cancelAllSyncTasks() {
        syncTasksQueue.sync { [weak self] in
            guard let self = self else { return }
            
            for (path, task) in self.syncTasks {
                task.cancel()
                Logger.shared.info(.sync, "取消同步任务: \(path)")
            }
            self.syncTasks.removeAll()
        }
    }
    
    // 统计方法已移至 statsQueue 保护上方
}

// MARK: - 同步统计

/// 同步统计
public struct SyncStatistics {
    public var totalSyncOperations: Int = 0
    public var successfulSyncOperations: Int = 0
    public var failedSyncOperations: Int = 0
    public var syncErrors: Int = 0
    public var lastSyncTime: Date?
    public var lastStartTime: Date?
    public var lastStopTime: Date?
    
    public var syncRate: Double {
        guard totalSyncOperations > 0 else { return 0 }
        return Double(successfulSyncOperations) / Double(totalSyncOperations)
    }
    
    public var uptime: TimeInterval? {
        guard let start = lastStartTime else { return nil }
        let end = lastStopTime ?? Date()
        return end.timeIntervalSince(start)
    }
}

// MARK: - FileMetadata 扩展已移至 SyncStatus.swift
