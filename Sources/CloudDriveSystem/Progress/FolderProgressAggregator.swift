//
//  FolderProgressAggregator.swift
//  CloudDriveSystem
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  macOS Finder 原生文件夹级联进度聚合器 (iCloud Drive 级全属性聚合与平滑防抖)
//

import Foundation
import CloudDriveContracts
import CloudDriveSupport

/// 文件夹层级进度聚合器
/// 负责追踪所有活跃文件传输，并向祖先文件夹级联发布 NSProgress，
/// 使 macOS Finder 在文件夹图标上显示同步圆环进度 (iCloud 体验)。
public final class FolderProgressAggregator: @unchecked Sendable {
    public static let shared = FolderProgressAggregator()
    
    public static let folderProgressDidUpdateNotification = Notification.Name("com.clouddrive.folderProgress.didUpdate")
    public static let folderProgressDidCompleteNotification = Notification.Name("com.clouddrive.folderProgress.didComplete")
    
    private struct ActiveItem {
        var completedBytes: Int64
        let totalBytes: Int64
        var speedBytesPerSec: Int64
    }
    
    private struct FolderState {
        let folderURL: URL
        let progress: Progress
        var activeItems: [String: ActiveItem] // [fileId: ActiveItem]
        var historicalCompletedBytes: Int64
        var pendingFinishWorkItem: DispatchWorkItem?
        var lastNotifiedTime: Date
    }
    
    private var folderStates: [String: FolderState] = [:] // [canonicalFolderPath: FolderState]
    private var fileToAncestorPaths: [String: [String]] = [:] // [fileId: [canonicalFolderPath]]
    private let lock = NSLock()
    
    private init() {}
    
    /// 当子文件开始传输时调用，向所有祖先目录注册并发布/更新进度
    public func fileDidStart(
        fileId: String,
        fileURL: URL,
        mountRootURL: URL,
        totalBytes: Int64,
        kind: Progress.FileOperationKind
    ) {
        lock.lock()
        defer { lock.unlock() }
        
        // 幂等防护：如果该 fileId 先前已处于活动状态（例如网络重试），先清理历史映射（非完成模式）
        if fileToAncestorPaths[fileId] != nil {
            internalFinishFile(fileId: fileId, isSuccess: false)
        }
        
        let ancestorURLs = resolveAncestorDirectoryURLs(fileURL: fileURL, mountRootURL: mountRootURL)
        guard !ancestorURLs.isEmpty else { return }
        
        let ancestorPaths = ancestorURLs.map { canonicalPath(for: $0) }
        fileToAncestorPaths[fileId] = ancestorPaths
        
        let now = Date()
        for folderURL in ancestorURLs {
            let path = canonicalPath(for: folderURL)
            var state: FolderState
            if let existing = folderStates[path] {
                state = existing
                // 如果存在待注销的延时任务，取消它（防频闪）
                state.pendingFinishWorkItem?.cancel()
                state.pendingFinishWorkItem = nil
            } else {
                let unitCount = totalBytes > 0 ? totalBytes : 100
                let progress = Progress(totalUnitCount: unitCount)
                progress.kind = .file
                progress.fileOperationKind = kind
                progress.fileURL = folderURL
                progress.isPausable = false
                progress.isCancellable = false
                
                // 注入 Apple 官方 UserInfo 元数据 (Finder 状态栏标准支持)
                progress.setUserInfoObject(kind, forKey: .fileOperationKindKey)
                progress.setUserInfoObject(folderURL, forKey: .fileURLKey)
                progress.publish()
                
                state = FolderState(
                    folderURL: folderURL,
                    progress: progress,
                    activeItems: [:],
                    historicalCompletedBytes: 0,
                    pendingFinishWorkItem: nil,
                    lastNotifiedTime: now
                )
            }
            
            state.activeItems[fileId] = ActiveItem(completedBytes: 0, totalBytes: totalBytes, speedBytesPerSec: 0)
            updateAggregatedUnits(for: &state)
            folderStates[path] = state
        }
    }
    
    /// 当子文件传输进度更新时调用，向上递归刷新各祖先目录的完成字节数及速率
    public func fileDidUpdate(fileId: String, completedBytes: Int64, speedBytesPerSec: Int64 = 0) {
        lock.lock()
        defer { lock.unlock() }
        
        guard let ancestorPaths = fileToAncestorPaths[fileId] else { return }
        let now = Date()
        
        for path in ancestorPaths {
            guard var state = folderStates[path] else { continue }
            if var item = state.activeItems[fileId] {
                item.completedBytes = completedBytes
                item.speedBytesPerSec = speedBytesPerSec
                state.activeItems[fileId] = item
                state.lastNotifiedTime = now
                updateAggregatedUnits(for: &state)
                folderStates[path] = state
            }
        }
    }
    
    /// 当子文件传输完成或取消时调用
    public func fileDidFinish(fileId: String) {
        lock.lock()
        defer { lock.unlock() }
        internalFinishFile(fileId: fileId)
    }
    
    /// 强制清理指定挂载点下或全量活跃文件夹进度 (用于保险库锁定 / 卸载生命周期)
    public func unpublishAll(under mountRootURL: URL? = nil) {
        lock.lock()
        defer { lock.unlock() }
        
        if let mountRoot = mountRootURL {
            let rootPrefix = canonicalPath(for: mountRoot)
            let matchingKeys = folderStates.keys.filter {
                $0.hasPrefix(rootPrefix)
            }
            for key in matchingKeys {
                if let state = folderStates.removeValue(forKey: key) {
                    state.pendingFinishWorkItem?.cancel()
                    state.progress.unpublish()
                }
            }
            fileToAncestorPaths = fileToAncestorPaths.compactMapValues { paths in
                let filtered = paths.filter { !$0.hasPrefix(rootPrefix) }
                return filtered.isEmpty ? nil : filtered
            }
        } else {
            for (_, state) in folderStates {
                state.pendingFinishWorkItem?.cancel()
                state.progress.unpublish()
            }
            folderStates.removeAll()
            fileToAncestorPaths.removeAll()
        }
    }
    
    /// 重置所有文件夹进度（注销并清空）
    public func reset() {
        unpublishAll(under: nil)
    }
    
    /// 获取当前正在广播进度的活跃文件夹路径列表 (供测试及监控)
    public func getActiveFolderPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(folderStates.keys)
    }
    
    /// 获取指定文件夹的聚合进度 (completedBytes, totalBytes)
    public func getFolderProgress(for path: String) -> (completedBytes: Int64, totalBytes: Int64)? {
        lock.lock()
        defer { lock.unlock() }
        let key = path.precomposedStringWithCanonicalMapping
        guard let state = folderStates[key] ?? folderStates[path] else { return nil }
        return (state.progress.completedUnitCount, state.progress.totalUnitCount)
    }
    
    // MARK: - Private Helpers
    
    private func internalFinishFile(fileId: String, isSuccess: Bool = true) {
        guard let ancestorPaths = fileToAncestorPaths.removeValue(forKey: fileId) else { return }
        
        for path in ancestorPaths {
            guard var state = folderStates[path] else { continue }
            if let item = state.activeItems.removeValue(forKey: fileId) {
                if isSuccess {
                    // 将已完成的字节累计入历史，保证进度单调递增不回退
                    let done = item.completedBytes > 0 ? item.completedBytes : item.totalBytes
                    state.historicalCompletedBytes += done
                }
            }
            
            if state.activeItems.isEmpty {
                // 该文件夹下所有传输全部完成，设置满格进度并启动 300ms 防抖注销
                state.progress.completedUnitCount = state.progress.totalUnitCount
                
                let work = DispatchWorkItem { [weak self] in
                    self?.finalizeUnpublish(folderPath: path)
                }
                state.pendingFinishWorkItem = work
                folderStates[path] = state
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            } else {
                updateAggregatedUnits(for: &state)
                folderStates[path] = state
            }
        }
    }
    
    private func updateAggregatedUnits(for state: inout FolderState) {
        var activeTotal: Int64 = 0
        var activeCompleted: Int64 = 0
        var aggregateSpeed: Int64 = 0
        
        for item in state.activeItems.values {
            activeTotal += item.totalBytes
            activeCompleted += item.completedBytes
            aggregateSpeed += item.speedBytesPerSec
        }
        
        let total = state.historicalCompletedBytes + activeTotal
        let completed = state.historicalCompletedBytes + activeCompleted
        let totalUnits = total > 0 ? total : 100
        
        state.progress.totalUnitCount = totalUnits
        state.progress.completedUnitCount = min(max(completed, 0), totalUnits)
        
        // 注入 Apple 官方 UserInfo 统计信息 (iCloud 原生体验)
        let totalItemsCount = state.activeItems.count
        let completedItemsCount = state.activeItems.values.filter { $0.completedBytes >= $0.totalBytes && $0.totalBytes > 0 }.count
        state.progress.setUserInfoObject(NSNumber(value: max(totalItemsCount, 1)), forKey: .fileTotalCountKey)
        state.progress.setUserInfoObject(NSNumber(value: completedItemsCount), forKey: .fileCompletedCountKey)
        
        if aggregateSpeed > 0 {
            state.progress.setUserInfoObject(NSNumber(value: aggregateSpeed), forKey: .throughputKey)
            let remainingBytes = max(total - completed, 0)
            let eta = Double(remainingBytes) / Double(aggregateSpeed)
            state.progress.setUserInfoObject(NSNumber(value: eta), forKey: .estimatedTimeRemainingKey)
        }
    }
    
    private func finalizeUnpublish(folderPath: String) {
        lock.lock()
        defer { lock.unlock() }
        
        guard let state = folderStates[folderPath], state.activeItems.isEmpty else {
            return
        }
        state.progress.unpublish()
        folderStates.removeValue(forKey: folderPath)
    }
    
    /// 解析从 fileURL 向上到 mountRootURL 之间的所有祖先文件夹 URL (支持跨字符集 Unicode 规范化比较)
    private func resolveAncestorDirectoryURLs(fileURL: URL, mountRootURL: URL) -> [URL] {
        var ancestors: [URL] = []
        var current = fileURL.deletingLastPathComponent().standardizedFileURL
        let root = mountRootURL.standardizedFileURL
        let rootPath = canonicalPath(for: root)
        
        while true {
            let currentPath = canonicalPath(for: current)
            if currentPath == rootPath || !currentPath.hasPrefix(rootPath) || currentPath == "/" {
                break
            }
            ancestors.append(current)
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if canonicalPath(for: parent) == currentPath { break }
            current = parent
        }
        return ancestors
    }
    
    private func canonicalPath(for url: URL) -> String {
        return url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
    }
}
