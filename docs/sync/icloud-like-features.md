# iCloud 风格功能实现方案

## 功能需求

### 1. 按需下载（On-Demand Download）
- 文件列表显示所有文件（不占用本地空间）
- 点击文件时才下载
- 显示下载进度

### 2. 智能缓存
- 下载后自动缓存
- 再次访问直接使用缓存
- 缓存命中率优化

### 3. 文件状态管理
- 🌐 **云端** - 文件在服务器，未下载
- ⬇️ **下载中** - 正在下载
- ✅ **已缓存** - 已下载到本地
- 📌 **固定** - 用户标记为始终保留

### 4. 自动缓存清理
- 设置缓存大小限制（如 10GB）
- 缓存满时自动清理最旧的文件
- 保留固定文件

## 实现架构

### 1. FileProviderItem 扩展

```swift
class FileProviderItem: NSObject, NSFileProviderItem {
    // 现有属性...
    
    // 新增：文件状态
    var downloadingStatus: NSFileProviderItemDownloadingStatus {
        if isDownloading {
            return .current  // 下载中
        } else if isCached {
            return .current  // 已缓存
        } else {
            return .notDownloaded  // 未下载
        }
    }
    
    // 新增：上传状态
    var uploadingStatus: NSFileProviderItemUploadingStatus {
        return .current  // 已同步
    }
    
    // 新增：是否固定
    var isMostRecentVersionDownloaded: Bool {
        return isCached
    }
}
```

### 2. CacheManager 增强

```swift
public class CacheManager {
    // 缓存策略
    enum CachePolicy {
        case automatic      // 自动管理
        case pinned        // 固定，不清理
        case temporary     // 临时，优先清理
    }
    
    // 缓存元数据
    struct CacheMetadata {
        let fileId: String
        let size: Int64
        let downloadedAt: Date
        let lastAccessedAt: Date
        let policy: CachePolicy
    }
    
    // 新增方法
    func setCachePolicy(fileId: String, policy: CachePolicy)
    func getCacheMetadata(fileId: String) -> CacheMetadata?
    func updateLastAccessed(fileId: String)
    func getCacheStatistics() -> (totalSize: Int64, fileCount: Int)
}
```

### 3. 下载进度跟踪

```swift
public class DownloadProgressTracker {
    static let shared = DownloadProgressTracker()
    
    private var activeDownloads: [String: Progress] = [:]
    
    func startDownload(fileId: String) -> Progress
    func updateProgress(fileId: String, progress: Double)
    func finishDownload(fileId: String)
    func cancelDownload(fileId: String)
    func getProgress(fileId: String) -> Progress?
}
```

## 详细实现

### 1. FileProviderItem 完整实现

```swift
import FileProvider
import UniformTypeIdentifiers

class FileProviderItem: NSObject, NSFileProviderItem {
    let identifier: NSFileProviderItemIdentifier
    let parentIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let capabilities: NSFileProviderItemCapabilities
    let documentSize: NSNumber?
    let contentModificationDate: Date?
    let creationDate: Date?
    
    // 缓存状态
    private let cacheManager = CacheManager.shared
    private var fileId: String { identifier.rawValue }
    
    var isCached: Bool {
        return cacheManager.isCached(fileId: fileId)
    }
    
    var isDownloading: Bool {
        return DownloadProgressTracker.shared.getProgress(fileId: fileId) != nil
    }
    
    // MARK: - NSFileProviderItem 协议
    
    var itemIdentifier: NSFileProviderItemIdentifier {
        return identifier
    }
    
    var parentItemIdentifier: NSFileProviderItemIdentifier {
        return parentIdentifier
    }
    
    // 下载状态
    var downloadingError: Error? {
        return nil
    }
    
    var isDownloaded: Bool {
        return isCached
    }
    
    var isDownloading: Bool {
        return isDownloading
    }
    
    var downloadingStatus: NSFileProviderItemDownloadingStatus {
        if isDownloading {
            return .current
        } else if isCached {
            return .current
        } else {
            return .notDownloaded
        }
    }
    
    // 上传状态
    var isUploaded: Bool {
        return true  // WebDAV 直接同步
    }
    
    var isUploading: Bool {
        return false
    }
    
    var uploadingError: Error? {
        return nil
    }
    
    // 最新版本
    var isMostRecentVersionDownloaded: Bool {
        return isCached
    }
    
    // 共享和收藏
    var isShared: Bool {
        return false
    }
    
    var isTrashed: Bool {
        return false
    }
    
    // 标签和用户信息
    var tagData: Data? {
        return nil
    }
    
    var favoriteRank: NSNumber? {
        return nil
    }
    
    var lastUsedDate: Date? {
        if let metadata = cacheManager.getCacheMetadata(fileId: fileId) {
            return metadata.lastAccessedAt
        }
        return nil
    }
    
    // 类型标识符
    var typeIdentifier: String {
        return contentType.identifier
    }
    
    // 子项数量（目录）
    var childItemCount: NSNumber? {
        if contentType == .folder {
            return nil  // 未知
        }
        return nil
    }
}
```

### 2. CacheManager 增强实现

```swift
public class CacheManager {
    public static let shared = CacheManager()
    
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let maxCacheSize: Int64 = 10 * 1024 * 1024 * 1024 // 10GB
    
    // 缓存元数据存储
    private var metadataStore: [String: CacheMetadata] = [:]
    private let metadataQueue = DispatchQueue(label: "com.clouddrive.cache.metadata")
    
    // 缓存策略
    public enum CachePolicy: Codable {
        case automatic
        case pinned
        case temporary
    }
    
    // 缓存元数据
    public struct CacheMetadata: Codable {
        let fileId: String
        let size: Int64
        let downloadedAt: Date
        var lastAccessedAt: Date
        var policy: CachePolicy
    }
    
    private init() {
        // 使用 App Group 共享目录
        let sharedContainerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.net.aabg.CloudDrive"
        )
        
        if let sharedContainerURL = sharedContainerURL {
            let appDir = sharedContainerURL.appendingPathComponent(".CloudDrive", isDirectory: true)
            self.cacheDirectory = appDir.appendingPathComponent("Cache", isDirectory: true)
        } else {
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            let appDir = homeDir.appendingPathComponent(".CloudDrive", isDirectory: true)
            self.cacheDirectory = appDir.appendingPathComponent("Cache", isDirectory: true)
        }
        
        // 确保目录存在
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        // 加载元数据
        loadMetadata()
        
        print("📁 缓存目录: \(cacheDirectory.path)")
    }
    
    // MARK: - 元数据管理
    
    private func loadMetadata() {
        let metadataURL = cacheDirectory.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode([String: CacheMetadata].self, from: data) else {
            return
        }
        metadataQueue.sync {
            self.metadataStore = metadata
        }
    }
    
    private func saveMetadata() {
        metadataQueue.async {
            let metadataURL = self.cacheDirectory.appendingPathComponent("metadata.json")
            if let data = try? JSONEncoder().encode(self.metadataStore) {
                try? data.write(to: metadataURL)
            }
        }
    }
    
    // MARK: - 公共方法
    
    public func localPath(for fileId: String) -> URL {
        return cacheDirectory.appendingPathComponent(fileId)
    }
    
    public func isCached(fileId: String) -> Bool {
        let path = localPath(for: fileId)
        return fileManager.fileExists(atPath: path.path)
    }
    
    public func cacheFile(fileId: String, from sourceURL: URL, policy: CachePolicy = .automatic) throws {
        let destinationURL = localPath(for: fileId)
        
        // 移动文件
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
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
        
        // 检查是否需要清理
        try cleanupIfNeeded()
    }
    
    public func updateLastAccessed(fileId: String) {
        metadataQueue.sync {
            metadataStore[fileId]?.lastAccessedAt = Date()
        }
        saveMetadata()
    }
    
    public func setCachePolicy(fileId: String, policy: CachePolicy) {
        metadataQueue.sync {
            metadataStore[fileId]?.policy = policy
        }
        saveMetadata()
    }
    
    public func getCacheMetadata(fileId: String) -> CacheMetadata? {
        return metadataQueue.sync {
            return metadataStore[fileId]
        }
    }
    
    public func getCacheStatistics() -> (totalSize: Int64, fileCount: Int) {
        return metadataQueue.sync {
            let totalSize = metadataStore.values.reduce(0) { $0