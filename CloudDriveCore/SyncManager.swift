//
//  SyncManager.swift
//  CloudDriveCore
//
//  文件同步管理器 - 处理本地和云端的同步
//

import Foundation
import Network

/// 文件同步管理器
public class SyncManager {
    public static let shared = SyncManager()
    
    private let fileManager = FileManager.default
    private let metadataQueue = DispatchQueue(label: "com.clouddrive.sync.metadata")
    private let syncQueue = DispatchQueue(label: "com.clouddrive.sync.operations")
    
    // 元数据存储
    private var fileMetadataStore: [String: FileMetadata] = [:]
    private let metadataURL: URL
    
    // 同步队列
    private var syncQueueItems: [SyncQueueItem] = []
    private let queueURL: URL
    
    // 网络监控
    private let networkMonitor = NWPathMonitor()
    private var networkStatus: NetworkStatus = .unknown
    private var isProcessingQueue = false
    
    // 存储客户端引用
    private var storageClient: StorageClient?
    
    // MARK: - 初始化
    
    private init() {
        // 使用 App Group 共享容器
        let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.net.aabg.CloudDrive")
        
        let appDir: URL
        if let sharedContainerURL = sharedContainerURL {
            appDir = sharedContainerURL.appendingPathComponent(".CloudDrive", isDirectory: true)
        } else {
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            appDir = homeDir.appendingPathComponent(".CloudDrive", isDirectory: true)
        }
        
        // 确保目录存在
        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true, attributes: nil)
        
        self.metadataURL = appDir.appendingPathComponent("sync_metadata.json")
        self.queueURL = appDir.appendingPathComponent("sync_queue.json")
        
        // 加载数据
        loadMetadata()
        loadSyncQueue()
        
        // 启动网络监控
        startNetworkMonitoring()
        
        logInfo(.sync, "同步管理器已初始化")
    }
    
    // MARK: - 配置
    
    /// 配置存储客户端
    public func configure(storageClient: StorageClient) {
        self.storageClient = storageClient
        logInfo(.sync, "存储客户端已配置")
    }
    
    // MARK: - 网络监控
    
    private func startNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            
            let newStatus: NetworkStatus = path.status == .satisfied ? .online : .offline
            
            if newStatus != self.networkStatus {
                self.networkStatus = newStatus
                logInfo(.sync, "网络状态变更: \(newStatus == .online ? "在线" : "离线")")
                
                // 如果网络恢复，处理同步队列
                if newStatus == .online {
                    self.processSyncQueue()
                }
            }
        }
        
        let queue = DispatchQueue(label: "com.clouddrive.network.monitor")
        networkMonitor.start(queue: queue)
    }
    
    /// 获取当前网络状态
    public func getNetworkStatus() -> NetworkStatus {
        return networkStatus
    }
    
    // MARK: - 元数据管理
    
    private func loadMetadata() {
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode([String: FileMetadata].self, from: data) else {
            logInfo(.sync, "同步元数据不存在或无法加载")
            return
        }
        
        metadataQueue.sync {
            self.fileMetadataStore = metadata
        }
        logSuccess(.sync, "加载同步元数据: \(metadata.count) 个文件")
    }
    
    private func saveMetadata() {
        metadataQueue.async {
            if let data = try? JSONEncoder().encode(self.fileMetadataStore) {
                try? data.write(to: self.metadataURL, options: [.atomic])
            }
        }
    }
    
    /// 更新文件元数据
    public func updateMetadata(_ metadata: FileMetadata) {
        metadataQueue.sync {
            fileMetadataStore[metadata.fileId] = metadata
        }
        saveMetadata()
    }
    
    /// 获取文件元数据
    public func getMetadata(fileId: String) -> FileMetadata? {
        return metadataQueue.sync {
            return fileMetadataStore[fileId]
        }
    }
    
    /// 删除文件元数据
    public func removeMetadata(fileId: String) {
        metadataQueue.sync {
            fileMetadataStore.removeValue(forKey: fileId)
        }
        saveMetadata()
    }
    
    /// 获取所有需要同步的文件
    public func getPendingSyncFiles() -> [FileMetadata] {
        return metadataQueue.sync {
            return fileMetadataStore.values.filter { $0.syncStatus.needsSync }
        }
    }
    
    // MARK: - 同步队列管理
    
    private func loadSyncQueue() {
        guard let data = try? Data(contentsOf: queueURL),
              let queue = try? JSONDecoder().decode([SyncQueueItem].self, from: data) else {
            logInfo(.sync, "同步队列不存在或无法加载")
            return
        }
        
        syncQueue.sync {
            self.syncQueueItems = queue
        }
        logSuccess(.sync, "加载同步队列: \(queue.count) 个项目")
    }
    
    private func saveSyncQueue() {
        syncQueue.async {
            if let data = try? JSONEncoder().encode(self.syncQueueItems) {
                try? data.write(to: self.queueURL, options: [.atomic])
            }
        }
    }
    
    /// 添加到同步队列
    public func addToSyncQueue(_ operation: SyncOperation) {
        let item = SyncQueueItem(operation: operation)
        
        syncQueue.sync {
            syncQueueItems.append(item)
        }
        saveSyncQueue()
        
        logInfo(.sync, "添加到同步队列: \(operation.fileId)")
        
        // 如果在线，立即处理
        if networkStatus == .online {
            processSyncQueue()
        }
    }
    
    /// 处理同步队列
    public func processSyncQueue() {
        guard networkStatus == .online else {
            logWarning(.sync, "离线状态，跳过同步队列处理")
            return
        }
        
        guard !isProcessingQueue else {
            logInfo(.sync, "同步队列正在处理中")
            return
        }
        
        isProcessingQueue = true
        
        Task {
            await processQueueAsync()
            isProcessingQueue = false
        }
    }
    
    private func processQueueAsync() async {
        let items = syncQueue.sync { syncQueueItems }
        
        guard !items.isEmpty else {
            logInfo(.sync, "同步队列为空")
            return
        }
        
        logInfo(.sync, "开始处理同步队列: \(items.count) 个项目")
        
        var processedItems: [String] = []
        var failedItems: [(String, String)] = []
        
        for item in items {
            do {
                try await processQueueItem(item)
                processedItems.append(item.id)
                logSuccess(.sync, "同步成功: \(item.operation.fileId)")
            } catch {
                failedItems.append((item.id, error.localizedDescription))
                logError(.sync, "同步失败: \(item.operation.fileId) - \(error.localizedDescription)")
                
                // 更新重试次数
                syncQueue.sync {
                    if let index = syncQueueItems.firstIndex(where: { $0.id == item.id }) {
                        var updatedItem = syncQueueItems[index]
                        updatedItem.retryCount += 1
                        updatedItem.lastError = error.localizedDescription
                        
                        // 如果重试次数超过3次，移除
                        if updatedItem.retryCount >= 3 {
                            syncQueueItems.remove(at: index)
                            logWarning(.sync, "同步失败次数过多，移除队列: \(item.operation.fileId)")
                        } else {
                            syncQueueItems[index] = updatedItem
                        }
                    }
                }
            }
        }
        
        // 移除成功处理的项目
        syncQueue.sync {
            syncQueueItems.removeAll { processedItems.contains($0.id) }
        }
        saveSyncQueue()
        
        logSuccess(.sync, "同步队列处理完成 - 成功: \(processedItems.count), 失败: \(failedItems.count)")
    }
    
    private func processQueueItem(_ item: SyncQueueItem) async throws {
        guard let storageClient = storageClient else {
            throw SyncError.storageNotConfigured
        }
        
        do {
            switch item.operation {
            case .upload(let fileId, let localPath, let remotePath):
                logInfo(.sync, "处理上传: \(fileId)")
                let localURL = URL(fileURLWithPath: localPath)
                
                // 检查本地文件是否存在
                guard fileManager.fileExists(atPath: localPath) else {
                    logError(.sync, "本地文件不存在: \(localPath)")
                    throw SyncError.operationFailed("本地文件不存在")
                }
                
                try await storageClient.uploadFile(localURL: localURL, to: remotePath) { _ in }
                logSuccess(.sync, "上传成功: \(fileId)")
                
                // 更新元数据
                if var metadata = self.getMetadata(fileId: fileId) {
                    metadata.syncStatus = .synced
                    metadata.remotePath = remotePath
                    metadata.remoteModifiedAt = Date()
                    self.updateMetadata(metadata)
                }
                
            case .download(let fileId, let remotePath, let localPath):
                logInfo(.sync, "处理下载: \(fileId)")
                let localURL = URL(fileURLWithPath: localPath)
                
                // 确保目标目录存在
                let parentDir = localURL.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: parentDir.path) {
                    try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
                }
                
                try await storageClient.downloadFile(path: remotePath, to: localURL) { progress in
                    // 更新下载进度
                    if var metadata = self.getMetadata(fileId: fileId) {
                        metadata.downloadProgress = progress
                        metadata.syncStatus = .downloading
                        self.updateMetadata(metadata)
                    }
                }
                logSuccess(.sync, "下载成功: \(fileId)")
                
                // 更新元数据
                if var metadata = self.getMetadata(fileId: fileId) {
                    metadata.syncStatus = .synced
                    metadata.localPath = localPath
                    metadata.localModifiedAt = Date()
                    self.updateMetadata(metadata)
                }
                
            case .delete(let fileId, let remotePath):
                logInfo(.sync, "处理删除: \(fileId)")
                try await storageClient.delete(path: remotePath)
                logSuccess(.sync, "删除成功: \(fileId)")
                removeMetadata(fileId: fileId)
                
            case .createDirectory(let directoryId, _, _, let remotePath):
                logInfo(.sync, "处理创建目录: \(directoryId)")
                try await storageClient.createDirectory(path: remotePath)
                logSuccess(.sync, "创建目录成功: \(directoryId)")
                
                // 更新元数据
                if var metadata = getMetadata(fileId: directoryId) {
                    metadata.syncStatus = .synced
                    metadata.remotePath = remotePath
                    updateMetadata(metadata)
                }
            }
        } catch {
            // 更新元数据为错误状态
            let fileId = item.operation.fileId
            if var metadata = getMetadata(fileId: fileId) {
                metadata.syncStatus = .error
                updateMetadata(metadata)
            }
            
            logError(.sync, "同步操作失败: \(fileId) - \(error.localizedDescription)")
            throw error
        }
    }
    
    /// 获取同步队列项目数量
    public func getSyncQueueCount() -> Int {
        return syncQueue.sync { syncQueueItems.count }
    }
    
    // MARK: - 同步状态检测
    
    /// 检测文件同步状态
    public func detectSyncStatus(fileId: String, localPath: String?, remotePath: String?) async -> SyncStatus {
        let hasLocal = localPath != nil && fileManager.fileExists(atPath: localPath!)
        let hasRemote = remotePath != nil
        
        // 检查是否在同步队列中
        let inQueue = syncQueue.sync {
            syncQueueItems.contains { $0.operation.fileId == fileId }
        }
        
        if inQueue {
            // 检查操作类型
            if let item = syncQueue.sync(execute: { syncQueueItems.first { $0.operation.fileId == fileId } }) {
                switch item.operation {
                case .upload:
                    return .pendingUpload
                case .delete:
                    return .pendingDelete
                default:
                    break
                }
            }
        }
        
        // 检查本地和远程状态
        if hasLocal && hasRemote {
            // 检查是否有冲突
            if let metadata = getMetadata(fileId: fileId), metadata.hasConflict() {
                return .conflict
            }
            return .synced
        } else if hasLocal && !hasRemote {
            return .localOnly
        } else if !hasLocal && hasRemote {
            return .cloudOnly
        } else {
            return .error
        }
    }
    
    /// 同步目录（比较本地和云端）
    public func syncDirectory(directoryId: String, localPath: String, remotePath: String) async throws -> [FileMetadata] {
        guard let storageClient = storageClient else {
            throw SyncError.storageNotConfigured
        }
        
        logInfo(.sync, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        logInfo(.sync, "开始同步目录: \(directoryId)")
        logInfo(.sync, "本地路径: \(localPath)")
        logInfo(.sync, "远程路径: \(remotePath)")
        logInfo(.sync, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        var syncedFiles: [FileMetadata] = []
        
        // 1. 获取云端文件列表
        var remoteFiles: [StorageResource] = []
        if networkStatus == .online {
            do {
                remoteFiles = try await storageClient.listDirectory(path: remotePath)
                logSuccess(.sync, "获取云端文件列表: \(remoteFiles.count) 个")
            } catch {
                logWarning(.sync, "获取云端文件列表失败: \(error.localizedDescription)")
            }
        }
        
        // 2. 获取本地文件列表
        var localFiles: [URL] = []
        if fileManager.fileExists(atPath: localPath) {
            do {
                localFiles = try fileManager.contentsOfDirectory(at: URL(fileURLWithPath: localPath), includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])
                logSuccess(.sync, "获取本地文件列表: \(localFiles.count) 个")
            } catch {
                logWarning(.sync, "获取本地文件列表失败: \(error.localizedDescription)")
            }
        }
        
        // 3. 比较和同步
        let remoteFileNames = Set(remoteFiles.map { $0.displayName })
        let localFileNames = Set(localFiles.map { $0.lastPathComponent })
        
        // 仅在云端的文件
        let cloudOnlyFiles = remoteFileNames.subtracting(localFileNames)
        logInfo(.sync, "仅在云端: \(cloudOnlyFiles.count) 个")
        
        for fileName in cloudOnlyFiles {
            if let resource = remoteFiles.first(where: { $0.displayName == fileName }) {
                let fileId = "\(remotePath)/\(fileName)"
                let metadata = FileMetadata(
                    fileId: fileId,
                    name: fileName,
                    parentId: directoryId,
                    isDirectory: resource.isDirectory,
                    syncStatus: .cloudOnly,
                    remotePath: resource.path,
                    size: resource.contentLength,
                    remoteModifiedAt: resource.lastModified,
                    etag: resource.etag
                )
                updateMetadata(metadata)
                syncedFiles.append(metadata)
            }
        }
        
        // 仅在本地的文件
        let localOnlyFiles = localFileNames.subtracting(remoteFileNames)
        logInfo(.sync, "仅在本地: \(localOnlyFiles.count) 个")
        
        for fileName in localOnlyFiles {
            if let fileURL = localFiles.first(where: { $0.lastPathComponent == fileName }) {
                let fileId = "\(remotePath)/\(fileName)"
                let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                let modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                
                let metadata = FileMetadata(
                    fileId: fileId,
                    name: fileName,
                    parentId: directoryId,
                    isDirectory: isDirectory,
                    syncStatus: .localOnly,
                    localPath: fileURL.path,
                    size: Int64(size),
                    localModifiedAt: modifiedAt
                )
                updateMetadata(metadata)
                syncedFiles.append(metadata)
                
                // 如果在线，添加到上传队列
                if networkStatus == .online {
                    let remoteFilePath = "\(remotePath)/\(fileName)"
                    if isDirectory {
                        addToSyncQueue(.createDirectory(directoryId: fileId, name: fileName, parentId: directoryId, remotePath: remoteFilePath))
                    } else {
                        addToSyncQueue(.upload(fileId: fileId, localPath: fileURL.path, remotePath: remoteFilePath))
                    }
                }
            }
        }
        
        // 同时存在的文件
        let commonFiles = remoteFileNames.intersection(localFileNames)
        logInfo(.sync, "同时存在: \(commonFiles.count) 个")
        
        for fileName in commonFiles {
            if let resource = remoteFiles.first(where: { $0.displayName == fileName }),
               let fileURL = localFiles.first(where: { $0.lastPathComponent == fileName }) {
                let fileId = "\(remotePath)/\(fileName)"
                let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                let localModifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                
                var metadata = FileMetadata(
                    fileId: fileId,
                    name: fileName,
                    parentId: directoryId,
                    isDirectory: isDirectory,
                    syncStatus: .synced,
                    localPath: fileURL.path,
                    remotePath: resource.path,
                    size: Int64(size),
                    localModifiedAt: localModifiedAt,
                    remoteModifiedAt: resource.lastModified,
                    etag: resource.etag
                )
                
                // 检查是否有冲突
                if metadata.hasConflict() {
                    metadata.syncStatus = .conflict
                    logWarning(.sync, "检测到冲突: \(fileName)")
                }
                
                updateMetadata(metadata)
                syncedFiles.append(metadata)
            }
        }
        
        logInfo(.sync, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        logSuccess(.sync, "目录同步完成: \(syncedFiles.count) 个文件")
        logInfo(.sync, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        return syncedFiles
    }
}

// MARK: - 同步错误

public enum SyncError: Error, LocalizedError {
    case storageNotConfigured
    case networkUnavailable
    case conflictDetected
    case operationFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .storageNotConfigured:
            return "存储未配置"
        case .networkUnavailable:
            return "网络不可用"
        case .conflictDetected:
            return "检测到冲突"
        case .operationFailed(let detail):
            return "操作失败: \(detail)"
        }
    }
}