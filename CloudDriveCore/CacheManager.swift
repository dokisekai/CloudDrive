//
//  CacheManager.swift
//  CloudDriveCore
//
//  本地缓存管理器 - iCloud 风格
//

import Foundation

/// 缓存管理器
public class CacheManager {
    public static let shared = CacheManager()
    
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let maxCacheSize: Int64 = 10 * 1024 * 1024 * 1024 // 10GB
    
    // 缓存元数据存储
    private var metadataStore: [String: CacheMetadata] = [:]
    private let metadataQueue = DispatchQueue(label: "com.clouddrive.cache.metadata")
    private let metadataURL: URL
    
    // MARK: - 缓存策略
    
    public enum CachePolicy: String, Codable {
        case automatic      // 自动管理
        case pinned        // 固定，不清理
        case temporary     // 临时，优先清理
    }
    
    // MARK: - 缓存元数据
    
    public struct CacheMetadata: Codable {
        public let fileId: String
        public let size: Int64
        public let downloadedAt: Date
        public var lastAccessedAt: Date
        public var policy: CachePolicy
        
        public init(fileId: String, size: Int64, downloadedAt: Date, lastAccessedAt: Date, policy: CachePolicy) {
            self.fileId = fileId
            self.size = size
            self.downloadedAt = downloadedAt
            self.lastAccessedAt = lastAccessedAt
            self.policy = policy
        }
    }
    
    private init() {
        // 使用App Group共享目录作为缓存目录，确保FileProvider扩展可以访问
        let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.net.aabg.CloudDrive")
        
        if let sharedContainerURL = sharedContainerURL {
            // 使用App Group共享目录
            let appDir = sharedContainerURL.appendingPathComponent(".CloudDrive", isDirectory: true)
            self.cacheDirectory = appDir.appendingPathComponent("Cache", isDirectory: true)
        } else {
            // 回退到用户主目录
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            let appDir = homeDir.appendingPathComponent(".CloudDrive", isDirectory: true)
            self.cacheDirectory = appDir.appendingPathComponent("Cache", isDirectory: true)
        }
        
        self.metadataURL = cacheDirectory.appendingPathComponent("metadata.json")
        
        // 确保目录存在
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: nil)
        
        // 加载元数据
        loadMetadata()
        
        Logger.shared.info(.cache, "缓存目录: \(cacheDirectory.path)")
        let stats = getCacheStatistics()
        Logger.shared.info(.cache, "缓存统计 - 文件数: \(stats.fileCount), 总大小: \(stats.totalSize) 字节")
    }
    
    // MARK: - 元数据管理
    
    private func loadMetadata() {
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode([String: CacheMetadata].self, from: data) else {
            Logger.shared.info(.cache, "缓存元数据不存在或无法加载，使用空元数据")
            return
        }
        metadataQueue.sync {
            self.metadataStore = metadata
        }
        Logger.shared.success(.cache, "加载缓存元数据: \(metadata.count) 个文件")
    }
    
    private func saveMetadata() {
        metadataQueue.async {
            if let data = try? JSONEncoder().encode(self.metadataStore) {
                try? data.write(to: self.metadataURL, options: [.atomic])
            }
        }
    }
    
    // MARK: - Public Methods
    
    /// 获取文件的本地缓存路径
    public func localPath(for fileId: String) -> URL {
        // fileId 是完整路径（如 /work/file.txt）
        // 需要移除开头的斜杠，并创建子目录结构
        var cleanPath = fileId
        if cleanPath.hasPrefix("/") {
            cleanPath = String(cleanPath.dropFirst())
        }
        
        let fullPath = cacheDirectory.appendingPathComponent(cleanPath)
        
        // 确保父目录存在
        let parentDir = fullPath.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try? fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true, attributes: nil)
        }
        
        return fullPath
    }
    
    /// 检查文件是否已缓存
    public func isCached(fileId: String) -> Bool {
        let path = localPath(for: fileId)
        return fileManager.fileExists(atPath: path.path)
    }
    
    /// 缓存文件
    public func cacheFile(fileId: String, data: Data) throws {
        let path = localPath(for: fileId)
        try data.write(to: path)
        try cleanupIfNeededInternal()
    }
    
    /// 缓存文件（从临时位置移动）
    public func cacheFile(fileId: String, from sourceURL: URL, policy: CachePolicy = .automatic) throws {
        let destinationURL = localPath(for: fileId)
        
        // 删除已存在的文件
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        
        // 移动文件
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
        
        // 保存元数据
        let size = try fileManager.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64 ?? 0
        let metadata = CacheMetadata(
            fileId: fileId,
            size: size,
            downloadedAt: Date(),
            lastAccessedAt: Date(),
            policy: policy
        )
        
        metadataQueue.sync {
            metadataStore[fileId] = metadata
        }
        saveMetadata()
        
        Logger.shared.success(.cache, "文件已缓存: \(fileId)")
        Logger.shared.info(.cache, "大小: \(size) 字节, 策略: \(policy.rawValue)")
        
        // 检查是否需要清理
        try cleanupIfNeededInternal()
    }
    
    /// 更新最后访问时间
    public func updateLastAccessed(fileId: String) {
        metadataQueue.sync {
            metadataStore[fileId]?.lastAccessedAt = Date()
        }
        saveMetadata()
    }
    
    /// 设置缓存策略
    public func setCachePolicy(fileId: String, policy: CachePolicy) {
        metadataQueue.sync {
            metadataStore[fileId]?.policy = policy
        }
        saveMetadata()
        Logger.shared.info(.cache, "设置缓存策略: \(fileId) -> \(policy.rawValue)")
    }
    
    /// 获取缓存元数据
    public func getCacheMetadata(fileId: String) -> CacheMetadata? {
        return metadataQueue.sync {
            return metadataStore[fileId]
        }
    }
    
    /// 获取缓存统计信息
    public func getCacheStatistics() -> (totalSize: Int64, fileCount: Int) {
        return metadataQueue.sync {
            let totalSize = metadataStore.values.reduce(0) { $0 + $1.size }
            let fileCount = metadataStore.count
            return (totalSize, fileCount)
        }
    }
    
    /// 读取缓存文件
    public func readCachedFile(fileId: String) throws -> Data {
        let path = localPath(for: fileId)
        return try Data(contentsOf: path)
    }
    
    /// 删除缓存文件
    public func removeCachedFile(fileId: String) throws {
        let path = localPath(for: fileId)
        if fileManager.fileExists(atPath: path.path) {
            try fileManager.removeItem(at: path)
        }
    }
    
    /// 清空所有缓存
    public func clearAllCache() throws {
        let contents = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
        for url in contents {
            try fileManager.removeItem(at: url)
        }
    }
    
    /// 获取当前缓存大小
    public func currentCacheSize() -> Int64 {
        return getCacheStatistics().totalSize
    }
    
    // MARK: - Public Cleanup Methods
    
    /// 根据需要清理缓存
    public func cleanupIfNeeded() throws {
        try self.cleanupIfNeededInternal()
    }
    
    // MARK: - Private Methods
    
    private func cleanupIfNeededInternal() throws {
        let stats = getCacheStatistics()
        if stats.totalSize > maxCacheSize {
            Logger.shared.warning(.cache, "缓存超限: \(stats.totalSize) / \(maxCacheSize) 字节")
            try cleanupOldestFiles(targetSize: maxCacheSize * 8 / 10)
        }
    }
    
    private func cleanupOldestFiles(targetSize: Int64) throws {
        Logger.shared.info(.cache, "开始清理缓存，目标: \(targetSize) 字节")
        
        // 获取所有可清理的文件（排除固定文件）
        let cleanableFiles = metadataQueue.sync {
            return metadataStore.values
                .filter { $0.policy != .pinned }
                .sorted { $0.lastAccessedAt < $1.lastAccessedAt }
        }
        
        var currentSize = getCacheStatistics().totalSize
        var cleanedCount = 0
        var cleanedSize: Int64 = 0
        
        for metadata in cleanableFiles {
            if currentSize <= targetSize { break }
            
            let fileURL = localPath(for: metadata.fileId)
            if fileManager.fileExists(atPath: fileURL.path) {
                do {
                    try fileManager.removeItem(at: fileURL)
                    currentSize -= metadata.size
                    cleanedSize += metadata.size
                    cleanedCount += 1
                    
                    // 删除元数据
                    metadataQueue.sync {
                        metadataStore.removeValue(forKey: metadata.fileId)
                    }
                    
                    Logger.shared.info(.cache, "清理文件: \(metadata.fileId), 大小: \(metadata.size) 字节")
                } catch {
                    Logger.shared.error(.cache, "清理失败: \(metadata.fileId), 错误: \(error)")
                }
            }
        }
        
        saveMetadata()
        
        Logger.shared.success(.cache, "缓存清理完成")
        Logger.shared.info(.cache, "清理文件数: \(cleanedCount)")
        Logger.shared.info(.cache, "释放空间: \(cleanedSize) 字节")
        Logger.shared.info(.cache, "当前大小: \(currentSize) 字节")
    }
}