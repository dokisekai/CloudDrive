//
//  FileMonitor.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  文件变更监控 - 本地监控 + 云端轮询
//

import Foundation
import Dispatch

/// 文件变更监控器
public class FileMonitor {
    public static let shared = FileMonitor()
    
    private let fileManager = FileManager.default
    private let syncManager = SyncManager.shared
    private let cacheManager = CacheManager.shared
    
    // 本地文件监控（使用 DispatchSource）
    private var localMonitors: [String: DispatchSourceFileSystemObject] = [:]
    private let monitorQueue = DispatchQueue(label: "com.clouddrive.filemonitor")
    
    // 云端轮询
    private var cloudPollingTimer: DispatchSourceTimer?
    private let cloudPollingQueue = DispatchQueue(label: "com.clouddrive.cloudpolling")
    private let pollingInterval: TimeInterval = 30 // 30秒轮询一次
    
    // 变更回调
    public var onChange: ((FileChangeEvent) -> Void)?
    
    // 已知的文件ETag（用于检测云端变化）
    private var knownFileETags: [String: String] = [:]
    private let etagsQueue = DispatchQueue(label: "com.clouddrive.etags")
    
    // 是否正在运行
    private var isMonitoring = false
    private let stateLock = NSLock()
    
    private init() {
        Logger.shared.info(.sync, "文件监控器已初始化")
    }
    
    // MARK: - 启动/停止监控
    
    /// 开始监控
    public func startMonitoring() {
        stateLock.lock()
        defer { stateLock.unlock() }
        
        guard !isMonitoring else {
            Logger.shared.warning(.sync, "文件监控已经在运行")
            return
        }
        
        isMonitoring = true
        Logger.shared.success(.sync, "开始文件监控")
        
        // 启动云端轮询
        startCloudPolling()
    }
    
    /// 停止监控
    public func stopMonitoring() {
        stateLock.lock()
        defer { stateLock.unlock() }
        
        guard isMonitoring else {
            Logger.shared.warning(.sync, "文件监控未在运行")
            return
        }
        
        isMonitoring = false
        Logger.shared.info(.sync, "停止文件监控")
        
        // 停止所有本地监控
        stopAllLocalMonitoring()
        
        // 停止云端轮询
        stopCloudPolling()
    }
    
    // MARK: - 本地文件监控
    
    /// 监控本地文件或目录
    public func monitorLocalPath(_ path: String) {
        monitorQueue.async { [weak self] in
            guard let self = self else { return }
            
            let fileURL = URL(fileURLWithPath: path)
            
            // 检查路径是否存在
            guard self.fileManager.fileExists(atPath: path) else {
                Logger.shared.warning(.sync, "路径不存在，无法监控: \(path)")
                return
            }
            
            // 检查是否已经监控
            if self.localMonitors[path] != nil {
                Logger.shared.info(.sync, "路径已在监控中: \(path)")
                return
            }
            
            // 创建文件描述符
            var fileDescriptor: CInt = -1
            var isDir: ObjCBool = false
            
            if self.fileManager.fileExists(atPath: path, isDirectory: &isDir) {
                fileDescriptor = open(path, O_EVTONLY)
            }
            
            guard fileDescriptor != -1 else {
                Logger.shared.error(.sync, "无法打开文件描述符: \(path)")
                return
            }
            
            // 创建 DispatchSource
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fileDescriptor,
                eventMask: .write,
                queue: self.monitorQueue
            )
            
            // 设置事件处理
            source.setEventHandler { [weak self] in
                guard let self = self else { return }
                
                let event = source.data
                Logger.shared.info(.sync, "检测到本地文件变化: \(path), 事件: \(event.rawValue)")
                
                // 延迟处理，避免频繁触发
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.handleLocalChange(path: path, isDirectory: isDir.boolValue)
                }
            }
            
            // 设置取消处理
            source.setCancelHandler {
                close(fileDescriptor)
                Logger.shared.info(.sync, "停止监控: \(path)")
            }
            
            // 恢复并保存
            source.resume()
            self.localMonitors[path] = source
            
            Logger.shared.success(.sync, "开始监控本地路径: \(path)")
        }
    }
    
    /// 停止监控指定路径
    public func stopMonitoringPath(_ path: String) {
        monitorQueue.async { [weak self] in
            guard let self = self else { return }
            
            if let monitor = self.localMonitors.removeValue(forKey: path) {
                monitor.cancel()
                Logger.shared.info(.sync, "停止监控: \(path)")
            }
        }
    }
    
    /// 停止所有本地监控
    private func stopAllLocalMonitoring() {
        monitorQueue.sync { [weak self] in
            guard let self = self else { return }
            
            for (path, monitor) in self.localMonitors {
                monitor.cancel()
                Logger.shared.info(.sync, "停止监控: \(path)")
            }
            self.localMonitors.removeAll()
        }
    }
    
    /// 处理本地文件变化
    private func handleLocalChange(path: String, isDirectory: Bool) {
        Logger.shared.info(.sync, "处理本地变化: \(path)")
        
        if isDirectory {
            // 目录变化，重新扫描
            handleDirectoryChange(path: path)
        } else {
            // 文件变化
            handleFileChange(path: path)
        }
    }
    
    /// 处理目录变化
    private func handleDirectoryChange(path: String) {
        // 获取目录中的所有文件
        guard let files = try? fileManager.contentsOfDirectory(atPath: path) else {
            Logger.shared.warning(.sync, "无法读取目录: \(path)")
            return
        }
        
        // 检查是否有新文件
        for fileName in files {
            let filePath = "\(path)/\(fileName)"
            var isFile: ObjCBool = true
            if fileManager.fileExists(atPath: filePath, isDirectory: &isFile), !isFile.boolValue {
                // 线程安全检查是否在监控中
                let isMonitored = monitorQueue.sync { localMonitors[filePath] != nil }
                if !isMonitored {
                    // 新文件，开始监控
                    monitorLocalPath(filePath)
                    
                    // 通知变化
                    notifyChange(
                        type: .fileCreated,
                        path: filePath,
                        isLocal: true
                    )
                }
            }
        }
    }
    
    /// 处理文件变化
    private func handleFileChange(path: String) {
        // 通知文件已修改
        notifyChange(
            type: .fileModified,
            path: path,
            isLocal: true
        )
        
        // 更新缓存元数据
        let fileId = path
        if cacheManager.isCached(fileId: fileId) {
            cacheManager.updateLastAccessed(fileId: fileId)
        }
    }
    
    // MARK: - 云端轮询
    
    /// 启动云端轮询
    private func startCloudPolling() {
        guard cloudPollingTimer == nil else { return }
        
        cloudPollingTimer = DispatchSource.makeTimerSource(
            flags: .strict,
            queue: cloudPollingQueue
        )
        
        cloudPollingTimer?.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            Task {
                await self.pollCloudChanges()
            }
        }
        
        cloudPollingTimer?.schedule(deadline: .now(), repeating: .seconds(Int64(pollingInterval)))
        cloudPollingTimer?.resume()
        
        Logger.shared.success(.sync, "云端轮询已启动，间隔: \(pollingInterval)秒")
    }
    
    /// 停止云端轮询
    private func stopCloudPolling() {
        cloudPollingTimer?.cancel()
        cloudPollingTimer = nil
        Logger.shared.info(.sync, "云端轮询已停止")
    }
    
    /// 轮询云端变化
    private func pollCloudChanges() async {
        guard let storageClient = syncManager.getStorageClient() else {
            Logger.shared.warning(.sync, "存储客户端未配置，无法轮询云端")
            return
        }
        
        Logger.shared.info(.sync, "开始轮询云端变化...")
        
        do {
            // 获取云端文件列表
            let remoteFiles = try await storageClient.listDirectory(path: "/")
            
            etagsQueue.sync {
                for remoteFile in remoteFiles {
                    let fileId = remoteFile.path
                    let currentETag = remoteFile.etag ?? ""
                    let previousETag = knownFileETags[fileId] ?? ""
                    
                    // 检查是否有变化
                    if currentETag != previousETag && previousETag != "" {
                        // ETag变化，文件已更新
                        Logger.shared.info(.sync, "检测到云端文件变化: \(fileId)")
                        Logger.shared.info(.sync, "  旧ETag: \(previousETag)")
                        Logger.shared.info(.sync, "  新ETag: \(currentETag)")
                        
                        // 通知变化
                        await MainActor.run {
                            notifyChange(
                                type: .fileModified,
                                path: fileId,
                                isLocal: false
                            )
                        }
                    }
                    
                    // 更新已知ETag
                    knownFileETags[fileId] = currentETag
                }
            }
            
            Logger.shared.success(.sync, "云端轮询完成，检查了 \(remoteFiles.count) 个文件")
            
        } catch {
            Logger.shared.error(.sync, "云端轮询失败: \(error)")
        }
    }
    
    /// 更新已知文件的ETag
    public func updateKnownETag(_ fileId: String, etag: String) {
        etagsQueue.sync {
            knownFileETags[fileId] = etag
        }
    }
    
    /// 清除已知的ETag
    public func clearKnownETags() {
        etagsQueue.sync {
            knownFileETags.removeAll()
        }
        Logger.shared.info(.sync, "已清除所有已知ETag")
    }
    
    // MARK: - 变更通知
    
    /// 通知文件变化
    private func notifyChange(type: FileChangeType, path: String, isLocal: Bool) {
        let event = FileChangeEvent(
            type: type,
            path: path,
            isLocal: isLocal,
            timestamp: Date()
        )
        
        Logger.shared.info(.sync, "文件变化通知: \(type) @ \(path) (\(isLocal ? "本地" : "云端"))")
        
        // 调用回调
        onChange?(event)
    }
    
    /// 主动触发云端同步检查
    public func triggerCloudSyncCheck() async {
        Logger.shared.info(.sync, "主动触发云端同步检查")
        await pollCloudChanges()
    }
}

// MARK: - 文件变更事件

/// 文件变更类型
public enum FileChangeType {
    case fileCreated      // 文件创建
    case fileModified      // 文件修改
    case fileDeleted       // 文件删除
    case directoryCreated  // 目录创建
    case directoryModified // 目录修改
    case directoryDeleted  // 目录删除
}

/// 文件变更事件
public struct FileChangeEvent {
    public let type: FileChangeType
    public let path: String
    public let isLocal: Bool
    public let timestamp: Date
    
    public var description: String {
        let location = isLocal ? "本地" : "云端"
        let typeDesc: String
        switch type {
        case .fileCreated: typeDesc = "文件创建"
        case .fileModified: typeDesc = "文件修改"
        case .fileDeleted: typeDesc = "文件删除"
        case .directoryCreated: typeDesc = "目录创建"
        case .directoryModified: typeDesc = "目录修改"
        case .directoryDeleted: typeDesc = "目录删除"
        }
        return "[\(location)] \(typeDesc): \(path)"
    }
}

