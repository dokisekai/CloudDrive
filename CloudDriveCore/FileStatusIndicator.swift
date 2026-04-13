//
//  FileStatusIndicator.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  文件状态指示器 - 显示文件同步状态
//

import Foundation
import Combine

/// 文件状态指示器
public class FileStatusIndicator {
    public static let shared = FileStatusIndicator()
    
    private let syncManager = SyncManager.shared
    private let cacheManager = CacheManager.shared
    private let conflictResolver = ConflictResolver.shared
    
    // 状态缓存
    private var statusCache: [String: FileStatus] = [:]
    private let statusQueue = DispatchQueue(label: "com.clouddrive.filestatus")
    
    // 状态变化通知
    private let statusChangeSubject = PassthroughSubject<FileStatusChangeEvent, Never>()
    public var statusChangePublisher: AnyPublisher<FileStatusChangeEvent, Never> {
        statusChangeSubject.eraseToAnyPublisher()
    }
    
    // 下载进度跟踪
    private var downloadProgress: [String: Double] = [:]
    private let progressQueue = DispatchQueue(label: "com.clouddrive.progress")
    
    // 是否启用实时状态更新
    private var realTimeUpdateEnabled: Bool = true
    
    private init() {
        Logger.shared.info(.sync, "文件状态指示器已初始化")
        
        // 启动状态更新任务
        startStatusUpdateTask()
    }
    
    // MARK: - 状态查询
    
    /// 获取文件状态
    public func getFileStatus(fileId: String) async -> FileStatus {
        // 检查缓存
        if let cachedStatus = getCachedStatus(fileId: fileId) {
            // 如果启用了实时更新，刷新缓存
            if realTimeUpdateEnabled {
                _ = await refreshStatus(fileId: fileId)
            }
            return cachedStatus
        }
        
        // 计算状态
        return await calculateStatus(fileId: fileId)
    }
    
    /// 获取文件状态（同步）
    public func getFileStatusSync(fileId: String) -> FileStatus {
        // 检查缓存
        if let cachedStatus = getCachedStatus(fileId: fileId) {
            return cachedStatus
        }
        
        // 返回默认状态
        return FileStatus(
            fileId: fileId,
            location: .unknown,
            syncState: .syncing,
            downloadProgress: 0.0,
            hasConflict: false,
            lastUpdated: Date()
        )
    }
    
    /// 批量获取文件状态
    public func getFileStatuses(fileIds: [String]) async -> [String: FileStatus] {
        var statuses: [String: FileStatus] = [:]
        
        for fileId in fileIds {
            statuses[fileId] = await getFileStatus(fileId: fileId)
        }
        
        return statuses
    }
    
    // MARK: - 状态计算
    
    /// 计算文件状态
    private func calculateStatus(fileId: String) async -> FileStatus {
        Logger.shared.debug(.sync, "计算文件状态: \(fileId)")
        
        let now = Date()
        
        // 1. 检查是否有冲突
        let hasConflict = await conflictResolver.detectConflict(fileId: fileId) != nil
        if hasConflict {
            let status = FileStatus(
                fileId: fileId,
                location: .both,
                syncState: .conflict,
                downloadProgress: 0.0,
                hasConflict: true,
                lastUpdated: now
            )
            updateCachedStatus(status)
            return status
        }
        
        // 2. 检查下载进度
        let downloadProgress = getDownloadProgress(fileId: fileId)
        if downloadProgress > 0 && downloadProgress < 1.0 {
            let status = FileStatus(
                fileId: fileId,
                location: .cloud,
                syncState: .downloading,
                downloadProgress: downloadProgress,
                hasConflict: false,
                lastUpdated: now
            )
            updateCachedStatus(status)
            return status
        }
        
        // 3. 检查是否在同步队列中
        let isInQueue = syncManager.getSyncQueueCount() > 0 && await isInSyncQueue(fileId: fileId)
        if isInQueue {
            let status = FileStatus(
                fileId: fileId,
                location: .local,
                syncState: .uploading,
                downloadProgress: 0.0,
                hasConflict: false,
                lastUpdated: now
            )
            updateCachedStatus(status)
            return status
        }
        
        // 4. 检查本地和云端状态
        let isCached = cacheManager.isCached(fileId: fileId)
        let metadata = syncManager.getMetadata(fileId: fileId)
        let isRemote = metadata?.remotePath != nil && metadata?.etag != ""
        
        if isCached && isRemote {
            // 都存在
            let status = FileStatus(
                fileId: fileId,
                location: .both,
                syncState: .synced,
                downloadProgress: 1.0,
                hasConflict: false,
                lastUpdated: now
            )
            updateCachedStatus(status)
            return status
            
        } else if isCached {
            // 仅本地
            let status = FileStatus(
                fileId: fileId,
                location: .local,
                syncState: .pendingUpload,
                downloadProgress: 0.0,
                hasConflict: false,
                lastUpdated: now
            )
            updateCachedStatus(status)
            return status
            
        } else if isRemote {
            // 仅云端
            let status = FileStatus(
                fileId: fileId,
                location: .cloud,
                syncState: .pendingDownload,
                downloadProgress: 0.0,
                hasConflict: false,
                lastUpdated: now
            )
            updateCachedStatus(status)
            return status
            
        } else {
            // 都不存在
            let status = FileStatus(
                fileId: fileId,
                location: .unknown,
                syncState: .error,
                downloadProgress: 0.0,
                hasConflict: false,
                lastUpdated: now
            )
            updateCachedStatus(status)
            return status
        }
    }
    
    /// 检查是否在同步队列中
    private func isInSyncQueue(fileId: String) async -> Bool {
        // 通过 SyncManager 检查
        let metadata = syncManager.getMetadata(fileId: fileId)
        return metadata?.syncStatus.needsSync ?? false
    }
    
    // MARK: - 状态缓存
    
    /// 获取缓存的状态
    private func getCachedStatus(fileId: String) -> FileStatus? {
        return statusQueue.sync {
            return statusCache[fileId]
        }
    }
    
    /// 更新缓存的状态
    private func updateCachedStatus(_ status: FileStatus) {
        statusQueue.sync {
            statusCache[status.fileId] = status
        }
    }
    
    /// 清除状态缓存
    public func clearCache(fileId: String) {
        statusQueue.sync {
            statusCache.removeValue(forKey: fileId)
        }
    }
    
    /// 清除所有状态缓存
    public func clearAllCache() {
        statusQueue.sync {
            statusCache.removeAll()
        }
        Logger.shared.info(.sync, "状态缓存已清除")
    }
    
    // MARK: - 状态更新
    
    /// 刷新文件状态
    public func refreshStatus(fileId: String) async -> FileStatus {
        Logger.shared.debug(.sync, "刷新文件状态: \(fileId)")
        
        let oldStatus = getCachedStatus(fileId: fileId)
        let newStatus = await calculateStatus(fileId: fileId)
        
        // 检查是否有变化
        if let oldStatus = oldStatus, oldStatus != newStatus {
            // 发送状态变化通知
            notifyStatusChange(from: oldStatus, to: newStatus)
        }
        
        return newStatus
    }
    
    /// 批量刷新状态
    public func refreshAllStatuses(fileIds: [String]) async -> [String: FileStatus] {
        var statuses: [String: FileStatus] = [:]
        
        for fileId in fileIds {
            statuses[fileId] = await refreshStatus(fileId: fileId)
        }
        
        return statuses
    }
    
    /// 通知状态变化
    private func notifyStatusChange(from oldStatus: FileStatus, to newStatus: FileStatus) {
        let event = FileStatusChangeEvent(
            fileId: newStatus.fileId,
            oldStatus: oldStatus,
            newStatus: newStatus,
            timestamp: Date()
        )
        
        Logger.shared.info(.sync, "文件状态变化: \(event.description)")
        
        // 发送通知
        statusChangeSubject.send(event)
    }
    
    // MARK: - 下载进度
    
    /// 设置下载进度
    public func setDownloadProgress(fileId: String, progress: Double) {
        progressQueue.async {
            self.downloadProgress[fileId] = progress
        }
        
        // 如果进度变化，刷新状态
        Task {
            await refreshStatus(fileId: fileId)
        }
    }
    
    /// 获取下载进度
    private func getDownloadProgress(fileId: String) -> Double {
        return progressQueue.sync {
            return downloadProgress[fileId] ?? 0.0
        }
    }
    
    /// 清除下载进度
    public func clearDownloadProgress(fileId: String) {
        progressQueue.async {
            self.downloadProgress.removeValue(forKey: fileId)
        }
    }
    
    // MARK: - 后台更新
    
    /// 启动状态更新任务
    private func startStatusUpdateTask() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + 5, repeating: 30) // 每5秒启动一次，每30秒更新一次
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            Task {
                await self.performStatusUpdate()
            }
        }
        timer.resume()
    }
    
    /// 执行状态更新
    private func performStatusUpdate() async {
        Logger.shared.debug(.sync, "执行状态更新...")
        
        // 获取需要更新的文件ID列表
        let fileIds = statusQueue.sync {
            return Array(statusCache.keys)
        }
        
        // 批量刷新状态
        _ = await refreshAllStatuses(fileIds: fileIds)
    }
    
    // MARK: - 配置
    
    /// 启用/禁用实时更新
    public func setRealTimeUpdateEnabled(_ enabled: Bool) {
        realTimeUpdateEnabled = enabled
        Logger.shared.info(.sync, "实时状态更新已\(enabled ? "启用" : "禁用")")
    }
}

// MARK: - 数据类型

/// 文件状态
public struct FileStatus: Equatable {
    public let fileId: String
    public let location: FileLocation
    public let syncState: SyncState
    public let downloadProgress: Double
    public let hasConflict: Bool
    public let lastUpdated: Date
    
    public init(fileId: String, location: FileLocation, syncState: SyncState, downloadProgress: Double, hasConflict: Bool, lastUpdated: Date) {
        self.fileId = fileId
        self.location = location
        self.syncState = syncState
        self.downloadProgress = downloadProgress
        self.hasConflict = hasConflict
        self.lastUpdated = lastUpdated
    }
    
    public var iconEmoji: String {
        switch syncState {
        case .synced:
            return "✅"
        case .downloading:
            return "⬇️"
        case .uploading:
            return "⬆️"
        case .pendingDownload:
            return "🌐"
        case .pendingUpload:
            return "📤"
        case .syncing:
            return "🔄"
        case .conflict:
            return "⚠️"
        case .error:
            return "❌"
        }
    }
    
    public var displayName: String {
        switch location {
        case .local:
            return "本地"
        case .cloud:
            return "云端"
        case .both:
            return "已同步"
        case .unknown:
            return "未知"
        }
    }
}

/// 文件位置
public enum FileLocation: Equatable {
    case local      // 仅本地
    case cloud      // 仅云端
    case both       // 本地和云端
    case unknown    // 未知
}

/// 同步状态
public enum SyncState: Equatable {
    case synced              // 已同步
    case downloading         // 下载中
    case uploading           // 上传中
    case pendingDownload     // 待下载
    case pendingUpload       // 待上传
    case syncing             // 同步中
    case conflict            // 冲突
    case error               // 错误
}

/// 文件状态变化事件
public struct FileStatusChangeEvent {
    public let fileId: String
    public let oldStatus: FileStatus
    public let newStatus: FileStatus
    public let timestamp: Date
    
    public var description: String {
        return "文件 \(fileId) 状态变化: \(oldStatus.syncState) -> \(newStatus.syncState)"
    }
    
    public var hasStateChanged: Bool {
        return oldStatus.syncState != newStatus.syncState
    }
    
    public var hasLocationChanged: Bool {
        return oldStatus.location != newStatus.location
    }
}

// MARK: - 文件状态工具函数

/// 获取文件状态图标的便捷函数
public func getFileStatusIcon(fileId: String) -> String {
    let fileStatus = FileStatusIndicator.shared.getFileStatusSync(fileId: fileId)
    return fileStatus.iconEmoji
}

/// 获取文件状态描述的便捷函数
public func getFileStatusDescription(fileId: String) -> String {
    let fileStatus = FileStatusIndicator.shared.getFileStatusSync(fileId: fileId)
    return "\(fileStatus.displayName) - \(fileStatus.syncState)"
}

/// 获取文件下载进度的便捷函数
public func getFileDownloadProgress(fileId: String) -> Double {
    let fileStatus = FileStatusIndicator.shared.getFileStatusSync(fileId: fileId)
    return fileStatus.downloadProgress
}
