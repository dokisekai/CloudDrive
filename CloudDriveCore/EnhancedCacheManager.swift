//
//  EnhancedCacheManager.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦jun liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  增强缓存管理器 - 智能预热 + 访问频率优化
//

import Foundation

/// 增强缓存管理器
public class EnhancedCacheManager {
    public static let shared = EnhancedCacheManager()
    
    private let baseCacheManager = CacheManager.shared
    private let syncManager = SyncManager.shared
    
    // 访问模式分析
    private var accessPatterns: [String: FileAccessPattern] = [:]
    private let patternQueue = DispatchQueue(label: "com.clouddrive.enhancedcache.pattern")
    
    // 预热任务
    private var prefetchTasks: [String: Task<Void, Never>] = [:]
    private let prefetchQueue = DispatchQueue(label: "com.clouddrive.enhancedcache.prefetch")
    
    // 缓存优化配置
    public var enableSmartPrefetch: Bool = true
    public var enableAccessFrequencyOptimization: Bool = true
    public var prefetchConcurrency: Int = 3 // 同时预取的文件数
    public var accessPatternLearningEnabled: Bool = true
    
    // 访问频率阈值
    private let frequentAccessThreshold: TimeInterval = 24 * 60 * 60 // 24小时内访问3次以上
    private let frequentAccessCount: Int = 3
    
    private init() {
        Logger.shared.info(.cache, "增强缓存管理器已初始化")
        
        // 启动后台优化任务
        startBackgroundOptimization()
    }
    
    // MARK: - 访问模式分析
    
    /// 记录文件访问
    public func recordAccess(fileId: String, accessType: FileAccessType = .read) {
        guard accessPatternLearningEnabled else { return }
        
        patternQueue.async { [weak self] in
            guard let self = self else { return }
            
            let now = Date()
            
            if var pattern = self.accessPatterns[fileId] {
                // 更新现有模式
                pattern.accessCount += 1
                pattern.lastAccessTime = now
                pattern.accessHistory.append(now)
                
                // 清理过期的访问历史（保留最近30天）
                let cutoffDate = now.addingTimeInterval(-30 * 24 * 60 * 60)
                pattern.accessHistory.removeAll { $0 < cutoffDate }
                
                self.accessPatterns[fileId] = pattern
                Logger.shared.debug(.cache, "更新访问模式: \(fileId), 访问次数: \(pattern.accessCount)")
            } else {
                // 创建新模式
                let pattern = FileAccessPattern(
                    fileId: fileId,
                    firstAccessTime: now,
                    lastAccessTime: now,
                    accessCount: 1,
                    accessHistory: [now],
                    accessType: accessType
                )
                self.accessPatterns[fileId] = pattern
                Logger.shared.debug(.cache, "创建访问模式: \(fileId)")
            }
        }
    }
    
    /// 获取文件访问频率
    public func getAccessFrequency(fileId: String) -> AccessFrequency {
        guard let pattern = accessPatterns[fileId] else {
            return .unknown
        }
        
        let now = Date()
        let recentAccesses = pattern.accessHistory.filter {
            now.timeIntervalSince($0) <= frequentAccessThreshold
        }
        
        if recentAccesses.count >= frequentAccessCount {
            return .frequent
        } else if recentAccesses.count > 0 {
            return .occasional
        } else {
            return .rare
        }
    }
    
    /// 预测即将访问的文件
    public func predictNextAccess(for fileId: String) -> [String] {
        guard enableSmartPrefetch, let pattern = accessPatterns[fileId] else {
            return []
        }
        
        // 基于访问历史预测
        var predictions: [String: Double] = [:]
        
        // 1. 同一目录的文件
        let directoryId = URL(fileURLWithPath: fileId).deletingLastPathComponent().path
        for (otherFileId, otherPattern) in accessPatterns {
            if otherFileId != fileId {
                let otherDirectoryId = URL(fileURLWithPath: otherFileId).deletingLastPathComponent().path
                
                // 如果在同一目录，增加预测权重
                if otherDirectoryId == directoryId {
                    let timeDiff = abs(pattern.lastAccessTime.timeIntervalSince(otherPattern.lastAccessTime))
                    if timeDiff < 3600 { // 1小时内访问过
                        predictions[otherFileId] = (predictions[otherFileId] ?? 0) + 0.8
                    } else if timeDiff < 86400 { // 24小时内访问过
                        predictions[otherFileId] = (predictions[otherFileId] ?? 0) + 0.5
                    }
                }
            }
        }
        
        // 2. 基于访问模式
        if pattern.accessCount > frequentAccessCount {
            // 高频文件，优先预取
            predictions[fileId] = (predictions[fileId] ?? 0) + 1.0
        }
        
        // 3. 按权重排序
        let sorted = predictions.sorted { $0.value > $1.value }
        return sorted.map { $0.key }
    }
    
    // MARK: - 智能预热
    
    /// 预热目录
    public func prefetchDirectory(directoryId: String) async {
        guard enableSmartPrefetch else { return }
        
        Logger.shared.info(.cache, "开始预热目录: \(directoryId)")
        
        do {
            // 获取目录中的文件列表
            guard let storageClient = syncManager.getStorageClient() else {
                Logger.shared.warning(.cache, "存储客户端未配置，无法预热")
                return
            }
            
            let files = try await storageClient.listDirectory(path: directoryId)
            let fileIds = files.map { $0.path }
            
            // 根据访问频率排序
            let prioritizedFiles = prioritizeFilesForPrefetch(fileIds)
            
            // 限制并发预热数量
            let filesToPrefetch = Array(prioritizedFiles.prefix(prefetchConcurrency))
            
            Logger.shared.info(.cache, "准备预热 \(filesToPrefetch.count) 个文件")
            
            // 并发预热
            await withTaskGroup(of: Void.self) { group in
                for fileId in filesToPrefetch {
                    group.addTask {
                        await self.prefetchFile(fileId: fileId)
                    }
                }
            }
            
            Logger.shared.success(.cache, "目录预热完成: \(directoryId)")
            
        } catch {
            Logger.shared.error(.cache, "预热目录失败: \(directoryId) - \(error)")
        }
    }
    
    /// 预热单个文件
    public func prefetchFile(fileId: String) async {
        guard enableSmartPrefetch else { return }
        
        // 检查是否已缓存
        if baseCacheManager.isCached(fileId: fileId) {
            Logger.shared.debug(.cache, "文件已缓存，跳过: \(fileId)")
            return
        }
        
        // 取消之前的预热任务（线程安全）
        let existingTask = prefetchQueue.sync { prefetchTasks[fileId] }
        existingTask?.cancel()
        
        let task = Task {
            do {
                Logger.shared.info(.cache, "开始预热文件: \(fileId)")
                
                guard let storageClient = syncManager.getStorageClient() else {
                    Logger.shared.warning(.cache, "存储客户端未配置")
                    return
                }
                
                // 下载到临时位置
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try await storageClient.downloadFile(path: fileId, to: tempURL) { _ in }
                
                // 移动到缓存
                try baseCacheManager.cacheFile(
                    fileId: fileId,
                    from: tempURL,
                    policy: determineCachePolicy(fileId: fileId)
                )
                
                Logger.shared.success(.cache, "文件预热成功: \(fileId)")
                
            } catch {
                if !Task.isCancelled {
                    Logger.shared.error(.cache, "预热文件失败: \(fileId) - \(error)")
                }
            }
        }
        
        prefetchQueue.sync {
            prefetchTasks[fileId] = task
        }
    }
    
    /// 取消预热
    public func cancelPrefetch(fileId: String) {
        prefetchQueue.sync {
            if let task = prefetchTasks.removeValue(forKey: fileId) {
                task.cancel()
                Logger.shared.info(.cache, "取消预热: \(fileId)")
            }
        }
    }
    
    /// 取消所有预热
    public func cancelAllPrefetches() {
        prefetchQueue.sync {
            for (fileId, task) in prefetchTasks {
                task.cancel()
                Logger.shared.info(.cache, "取消预热: \(fileId)")
            }
            prefetchTasks.removeAll()
        }
    }
    
    /// 确定缓存策略
    private func determineCachePolicy(fileId: String) -> CacheManager.CachePolicy {
        guard enableAccessFrequencyOptimization else {
            return .automatic
        }
        
        switch getAccessFrequency(fileId) {
        case .frequent:
            return .pinned // 高频文件固定缓存
        case .occasional:
            return .automatic // 偶尔访问的文件自动管理
        case .rare, .unknown:
            return .temporary // 稀有访问的文件临时缓存
        }
    }
    
    /// 为预热优先排序文件
    private func prioritizeFilesForPrefetch(_ fileIds: [String]) -> [String] {
        var prioritized: [(fileId: String, score: Double)] = []
        
        for fileId in fileIds {
            var score: Double = 0
            
            // 1. 访问频率权重
            switch getAccessFrequency(fileId) {
            case .frequent:
                score += 3.0
            case .occasional:
                score += 1.5
            case .rare:
                score += 0.5
            case .unknown:
                score += 0
            }
            
            // 2. 最近访问时间权重
            if let pattern = accessPatterns[fileId] {
                let timeSinceAccess = Date().timeIntervalSince(pattern.lastAccessTime)
                let recencyScore = max(0, 2.0 - timeSinceAccess / (24 * 60 * 60)) // 24小时内递减
                score += recencyScore
            }
            
            // 3. 文件大小权重（小文件优先）
            if let metadata = syncManager.getMetadata(fileId: fileId) {
                let sizeMB = Double(metadata.size) / (1024 * 1024)
                let sizeScore = max(0, 1.0 - sizeMB / 100) // 超过100MB权重为0
                score += sizeScore
            }
            
            prioritized.append((fileId: fileId, score: score))
        }
        
        // 按分数降序排序
        return prioritized.sorted { $0.score > $1.score }.map { $0.fileId }
    }
    
    // MARK: - 访问频率优化
    
    /// 优化缓存策略
    public func optimizeCachePolicies() async {
        guard enableAccessFrequencyOptimization else { return }
        
        Logger.shared.info(.cache, "开始优化缓存策略...")
        
        var updatedCount = 0
        
        for (fileId, pattern) in accessPatterns {
            // 获取当前缓存策略
            guard let metadata = syncManager.getMetadata(fileId: fileId),
                  baseCacheManager.isCached(fileId: fileId) else {
                continue
            }
            
            let currentPolicy = baseCacheManager.getCacheMetadata(fileId: fileId)?.policy ?? .automatic
            let recommendedPolicy = determineCachePolicy(fileId: fileId)
            
            // 更新策略
            if currentPolicy != recommendedPolicy {
                baseCacheManager.setCachePolicy(fileId: fileId, policy: recommendedPolicy)
                updatedCount += 1
                Logger.shared.debug(.cache, "更新缓存策略: \(fileId) -> \(recommendedPolicy)")
            }
        }
        
        Logger.shared.success(.cache, "缓存策略优化完成，更新了 \(updatedCount) 个文件")
    }
    
    /// 清理低访问频率的缓存
    public async func cleanupLowFrequencyCache() {
        Logger.shared.info(.cache, "开始清理低访问频率缓存...")
        
        var removedCount = 0
        
        for (fileId, _) in accessPatterns {
            let frequency = getAccessFrequency(fileId: fileId)
            
            // 清理稀有访问的临时缓存
            if frequency == .rare || frequency == .unknown {
                if let metadata = baseCacheManager.getCacheMetadata(fileId: fileId),
                   metadata.policy == .temporary {
                    try? baseCacheManager.removeCachedFile(fileId: fileId)
                    removedCount += 1
                    Logger.shared.debug(.cache, "清理低频缓存: \(fileId)")
                }
            }
        }
        
        Logger.shared.success(.cache, "低频缓存清理完成，清理了 \(removedCount) 个文件")
    }
    
    // MARK: - 后台优化
    
    // 后台优化定时器
    private var backgroundOptTimer: DispatchSourceTimer?
    
    /// 启动后台优化
    private func startBackgroundOptimization() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + 60, repeating: 600)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            Task {
                await self.performBackgroundOptimization()
            }
        }
        timer.resume()
        self.backgroundOptTimer = timer
    }
    
    /// 执行后台优化
    private func performBackgroundOptimization() async {
        Logger.shared.info(.cache, "执行后台缓存优化...")
        
        // 1. 优化缓存策略
        await optimizeCachePolicies()
        
        // 2. 清理低频缓存
        await cleanupLowFrequencyCache()
        
        Logger.shared.success(.cache, "后台缓存优化完成")
    }
    
    // MARK: - 统计信息
    
    /// 获取缓存统计
    public func getEnhancedStatistics() -> CacheStatistics {
        let baseStats = baseCacheManager.getCacheStatistics()
        
        let frequentCount = accessPatterns.values.filter { getAccessFrequency(fileId: $0.fileId) == .frequent }.count
        let occasionalCount = accessPatterns.values.filter { getAccessFrequency(fileId: $0.fileId) == .occasional }.count
        let rareCount = accessPatterns.values.filter { getAccessFrequency(fileId: $0.fileId) == .rare }.count
        
        return CacheStatistics(
            totalSize: baseStats.totalSize,
            fileCount: baseStats.fileCount,
            frequentAccessCount: frequentCount,
            occasionalAccessCount: occasionalCount,
            rareAccessCount: rareCount,
            pinnedFileCount: accessPatterns.values.filter {
                baseCacheManager.getCacheMetadata(fileId: $0.fileId)?.policy == .pinned
            }.count,
            temporaryFileCount: accessPatterns.values.filter {
                baseCacheManager.getCacheMetadata(fileId: $0.fileId)?.policy == .temporary
            }.count
        )
    }
}

// MARK: - 数据类型

/// 访问模式
public struct FileAccessPattern {
    public let fileId: String
    public let firstAccessTime: Date
    public var lastAccessTime: Date
    public var accessCount: Int
    public var accessHistory: [Date]
    public var accessType: FileAccessType
    
    public init(fileId: String, firstAccessTime: Date, lastAccessTime: Date, accessCount: Int, accessHistory: [Date], accessType: FileAccessType) {
        self.fileId = fileId
        self.firstAccessTime = firstAccessTime
        self.lastAccessTime = lastAccessTime
        self.accessCount = accessCount
        self.accessHistory = accessHistory
        self.accessType = accessType
    }
}

/// 访问频率
public enum AccessFrequency {
    case frequent    // 频繁访问
    case occasional  // 偶尔访问
    case rare       // 稀有访问
    case unknown    // 未知
}

/// 访问类型
public enum FileAccessType {
    case read   // 读取
    case write  // 写入
}

/// 增强缓存统计
public struct CacheStatistics {
    public let totalSize: Int64
    public let fileCount: Int
    public let frequentAccessCount: Int
    public let occasionalAccessCount: Int
    public let rareAccessCount: Int
    public let pinnedFileCount: Int
    public let temporaryFileCount: Int
    
    public init(totalSize: Int64, fileCount: Int, frequentAccessCount: Int = 0, occasionalAccessCount: Int = 0, rareAccessCount: Int = 0, pinnedFileCount: Int = 0, temporaryFileCount: Int = 0) {
        self.totalSize = totalSize
        self.fileCount = fileCount
        self.frequentAccessCount = frequentAccessCount
        self.occasionalAccessCount = occasionalAccessCount
        self.rareAccessCount = rareAccessCount
        self.pinnedFileCount = pinnedFileCount
        self.temporaryFileCount = temporaryFileCount
    }
}
