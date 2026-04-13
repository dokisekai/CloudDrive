# CloudDrive 同步模块索引

## 文档信息

- **版本**: v1.0
- **创建日期**: 2026-04-10
- **作者**: 李彦军 (liyanjun@aabg.net)
- **设计原则**: 最小功能化、单一职责

---

## 目录结构

```
CloudDriveCore/
├── SyncManager.swift                    # 同步协调器（主入口）
├── SyncStatus.swift                      # 同步状态定义
├── FileProviderSync.swift                # 跨进程同步
├── FileMonitor.swift                     # 文件变更监控
├── EnhancedSyncManager.swift             # 增强同步管理
├── ConflictResolver.swift                # 冲突解决器
├── EnhancedCacheManager.swift            # 智能缓存管理
├── FileStatusIndicator.swift             # 文件状态指示
├── CacheManager.swift                    # 缓存管理器
├── FileOperationManager.swift           # 文件操作管理
└── CloudFile.swift                        # 云文件模型
```

---

## 模块详细索引

### 模块 01: NetworkMonitor（网络监控器）

**文件**: `SyncManager.swift` (Lines 78-97)
**职责**: 监控网络连接状态
**依赖**: `Network` 框架

#### 最小功能单元

| 功能 | 方法/属性 | 描述 |
|------|-----------|------|
| 监控网络 | `startNetworkMonitoring()` | 启动网络状态监控 |
| 状态查询 | `networkStatus: NetworkStatus` | 当前网络状态 |
| 状态通知 | `pathUpdateHandler` | 网络状态变化回调 |

#### 接口定义

```swift
protocol NetworkMonitor {
    var networkStatus: NetworkStatus { get }
    func startMonitoring()
}

enum NetworkStatus {
    case online
    case offline
    case limited
}
```

#### 不负责

- ❌ 文件操作
- ❌ 同步逻辑
- ❌ 队列管理

---

### 模块 02: MetadataStore（元数据存储器）

**文件**: `SyncManager.swift` (Lines 22-26, 82-107)
**职责**: 持久化文件元数据
**依赖**: `FileManager`

#### 最小功能单元

| 功能 | 方法/属性 | 描述 |
|------|-----------|------|
| 保存元数据 | `saveMetadata()` | 保存到磁盘 |
| 读取元数据 | `getMetadata()` | 从磁盘读取 |
| 删除元数据 | `removeMetadata()` | 删除元数据 |
| 更新元数据 | `updateMetadata()` | 更新元数据 |

#### 接口定义

```swift
protocol MetadataStore {
    func save(_ metadata: FileMetadata) throws
    func load(fileId: String) -> FileMetadata?
    func delete(fileId: String) throws
    func update(_ metadata: FileMetadata) throws
}
```

#### 数据结构

```swift
struct FileMetadata: Codable {
    let fileId: String
    let name: String
    let parentId: String
    let isDirectory: Bool
    var syncStatus: SyncStatus
    var localPath: String?
    var remotePath: String?
    var size: Int64
    var localModifiedAt: Date?
    var remoteModifiedAt: Date?
    var etag: String?
    var downloadProgress: Double
}
```

#### 不负责

- ❌ 同步操作
- ❌ 网络请求
- ❌ 文件传输

---

### 模块 03: SyncQueue（同步队列）

**文件**: `SyncManager.swift` (Lines 27-28, 109-125)
**职责**: 管理待执行同步任务
**依赖**: `MetadataStore`

#### 最小功能单元

| 功能 | 方法/属性 | 描述 |
|------|-----------|------|
| 添加任务 | `addToSyncQueue()` | 添加到队列 |
| 获取任务 | `getNextSyncItem()` | 获取下一个任务 |
| 队列大小 | `getSyncQueueCount()` | 队列中的任务数 |
| 队列持久化 | `saveSyncQueue()` / `loadSyncQueue()` | 保存/加载队列 |

#### 接口定义

```swift
protocol SyncQueue {
    func enqueue(_ operation: SyncOperation)
    func dequeue() -> SyncOperation?
    func count() -> Int
    func peek() -> SyncOperation?
    func clear()
}

enum SyncOperation: Codable {
    case upload(fileId: String, localPath: String, remotePath: String)
    case download(fileId: String, remotePath: String, localPath: String)
    case delete(fileId: String, remotePath: String)
    case createDirectory(directoryId: String, name: String, parentId: String, remotePath: String)
}
```

#### 数据结构

```swift
struct SyncQueueItem: Codable {
    let id: String
    let operation: SyncOperation
    let createdAt: Date
    var retryCount: Int
    var lastError: String?
}
```

#### 不负责

- ❌ 任务执行
- ❌ 任务重试逻辑
- ❌ 任务优先级排序

---

### 模块 04: QueueProcessor（队列处理器）

**文件**: `SyncManager.swift` (Lines 127-189)
**职责**: 处理队列中的同步任务
**依赖**: `SyncQueue`, `FileUploader`, `FileDownloader`, `FileDeleter`

#### 最小功能单元

| 功能 | 方法/属性 | 描述 |
|------|-----------|------|
| 处理队列 | `processSyncQueue()` | 处理队列中的任务 |
| 执行操作 | `processSyncItem()` | 执行单个同步操作 |
| 错误处理 | `handleSyncError()` | 处理同步错误 |

#### 接口定义

```swift
protocol QueueProcessor {
    func process(queue: SyncQueue) async
    var onTaskComplete: ((SyncOperation, Error?) -> Void)? { get set }
}
```

#### 处理流程

```
1. 从队列获取任务
2. 根据操作类型分发
3. 等待操作完成
4. 更新任务状态
5. 处理错误（重试或标记失败）
6. 继续下一个任务
```

#### 不负责

- ❌ 任务执行细节
- ❌ 队列管理
- ❌ 冲突检测

---

### 模块 05: FileUploader（文件上传器）

**文件**: `SyncManager.swift` (Lines 298-312)
**职责**: 执行文件上传操作
**依赖**: `StorageClient`

#### 最小功能单元

| 功能 | 方法/属性 | 描述 |
|------|-----------|------|
| 上传文件 | `uploadFile()` | 上传本地文件到云端 |
| 进度报告 | `progress: (Double) -> Void` | 上传进度回调 |

#### 接口定义

```swift
protocol FileUploader {
    func upload(
        local: URL,
        to remote: String,
        progress: ((Double) -> Void)?
    ) async throws
}
```

#### 不负责

- ❌ 队列管理
- ❌ 冲突解决
- ❌ 网络重试（由 StorageClient 负责）

---

### 模块 06: FileDownloader（文件下载器）

**文件**: `SyncManager.swift` (Lines 274-290)
**职责**: 执行文件下载操作
**依赖**: `StorageClient`

#### 最小功能单元

| 功能 | 方法/属性 | 描述 |
|------|-----------|------|
| 下载文件 | `downloadFile()` | 从云端下载文件 |
| 进度报告 | `progress: (Double) -> Void` | 下载进度回调 |

#### 接口定义

```swift
protocol FileDownloader {
    func download(
        from remote: String,
        to local: URL,
        progress: ((Double) -> Void)?
    ) async throws
}
```

#### 不负责

- ❌ 队列管理
- ❌ 缓存写入（由调用者负责）
- ❌ 网络重试（由 StorageClient 负责）

---

### 模块 07: FileDeleter（文件删除器）

**文件**: `SyncManager.swift` (Lines 323-327)
**职责**: 执行文件删除操作
**依赖**: `StorageClient`

#### 最小功能单元

| 功能 | 方法/属性 | 描述 |
|------|-----------|------|
| 删除云端 | `deleteRemote()` | 删除云端文件 |
| 删除本地 | `deleteLocal()` | 删除本地文件 |

#### 接口定义

```swift
protocol FileDeleter {
    func deleteRemote(path: String) async throws
    func deleteLocal(path: String) throws
}
```

#### 不负责

- ❌ 队列管理
- ❌ 冲突解决
- ❌ 回收站处理

---

### 模块 08: ConflictDetector（冲突检测器）

**文件**: `ConflictResolver.swift` (Lines 88-127)
**职责**: 检测文件冲突
**依赖**: `MetadataStore`, `CacheManager`

#### 最小功能单元

| 功能 | 方法/属性 | 描述 |
|------|-----------|------|
| 检测冲突 | `detectConflict()` | 检测文件是否冲突 |
| 批量检测 | `detectAllConflicts()` | 批量检测冲突 |
| 内容差异 | `hasContentDifference()` | 检查内容是否不同 |

#### 接口定义

```swift
protocol ConflictDetector {
    func detect(fileId: String) async -> ConflictInfo?
    func detectAll() async -> [ConflictInfo]
}

enum ConflictType {
    case localOnly
    case remoteOnly
    case modificationConflict
    case contentDifference
}
```

#### 检测逻辑

```
1. 检查本地和远程是否存在
2. 比较修改时间
3. 检查内容差异（大小、ETag）
4. 判断冲突类型
5. 返回冲突信息
```

#### 不负责

- ❌ 冲突解决
- ❌ 文件操作
- ❌ 用户交互

---

### 模块 09: ConflictResolver（冲突解决器）

**文件**: `ConflictResolver.swift` (Lines 129-289)
**职责**: 解决文件冲突
**依赖**: `ConflictDetector`, `FileUploader`, `FileDownloader`, `FileManager`

#### 最小功能单元

| 功能 | 方法/属性 | 描述 |
|------|-----------|------|
| 解决冲突 | `resolveConflict()` | 根据策略解决冲突 |
| 本地优先 | `resolveLocalOnlyConflict()` | 保留本地版本 |
| 云端优先 | `resolveRemoteOnlyConflict()` | 保留云端版本 |
| 重命名 | `resolveModificationConflict()` | 重命名冲突文件 |

#### 接口定义

```swift
protocol ConflictResolver {
    func resolve(
        _ conflict: ConflictInfo,
        policy: ConflictResolutionPolicy
    ) async throws -> ConflictResolution
}

enum ConflictResolutionPolicy {
    case localWins
    case remoteWins
    case renameLocal
    case askUser
}
```

#### 解决策略

| 策略 | 动作 | 适用场景 |
|------|------|---------|
| localWins | 上传本地到云端 | 用户希望保留本地修改 |
| remoteWins | 下载云端到本地 | 用户希望使用云端版本 |
| renameLocal | 重命名本地 + 下载云端 | 保留两个版本 |
| askUser | 显示对话框让用户选择 | 用户明确的选择 |

#### 不负责

- ❌ 冲突检测
- ❌ 策略选择（由用户或配置决定）

---

### 模块 10: CacheHitDetector（缓存命中检测器）

**文件**: `CacheManager.swift` (Lines 124-128)
**职责**: 检测文件是否已缓存
**依赖**: `FileManager`

#### 最小功能单元

| 功能 | 方法/属性 | 描述 |
|------|-----------|------|
| 检测缓存 | `isCached()` | 检查文件是否已缓存 |
| 获取路径 | `localPath()` | 获取文件本地路径 |

#### 接口定义

```swift
protocol CacheHitDetector {
    func isCached(fileId: String) -> Bool
    func cachePath(for fileId: String) -> URL
}
```

#### 不负责

- ❌ 缓存写入
- ❌ 缓存清理
- ❌ 缓存策略

---

### 模块 11: CacheWriter（缓存写入器）

**文件**: `CacheManager.swift` (Lines 131-169)
**职责**: 写入文件到缓存
**依赖**: `FileManager`, `MetadataStore`

#### 最小功能单元

| 功能 | 方法/属性 | 描述 |
|------|-----------|------|
| 写入缓存 | `cacheFile()` | 保存文件到缓存 |
| 保存元数据 | `saveMetadata()` | 保存缓存元数据 |
| 更新访问 | `updateLastAccessed()` | 更新最后访问时间 |

#### 接口定义

```swift
protocol CacheWriter {
    func write(
        fileId: String,
        from source: URL,
        policy: CachePolicy
    ) throws
}

enum CachePolicy {
    case automatic
    case pinned
    case temporary
}
```

#### 不负责

- ❌ 缓存命中检测
- ❌ 缓存清理
- ❌ 文件下载

---

### 模块 12: CacheCleaner（缓存清理器）

**文件**: `CacheManager.swift` (Lines 210-291)
**职责**: 清理过期或过多的缓存
**依赖**: `FileManager`, `MetadataStore`

#### 最小功能单元

| 功能 | 方法/属性 | 描述 |
|------|-----------|------|
| 清理缓存 | `cleanupIfNeeded()` | 根据需要清理 |
| 清理所有 | `clearAllCache()` | 清空所有缓存 |
| 删除文件 | `removeCachedFile()` | 删除指定缓存文件 |

#### 接口定义

```swift
protocol CacheCleaner {
    func cleanupIfNeeded() throws
    func clearAll() throws
    func clear(fileId: String) throws
}
```

#### 清理策略

```
1. 检查当前缓存大小
2. 如果超过限制：
   a. 排除固定缓存
   b. 按最后访问时间排序
   c. 删除最旧的缓存
   d. 直到缓存大小降到目标值以下
```

#### 不负责

- ❌ 缓存命中检测
- ❌ 缓存写入
- ❌ 缓存策略选择

---

### 模块 13: LocalFileMonitor（本地文件监控器）

**文件**: `FileMonitor.swift` (Lines 68-134)
**职责**: 监控本地文件系统变化
**依赖**: `DispatchSourceFileSystemObject`

#### 最小功能单元

| 功能 | 方法/属性 | 描述 |
|------|-----------|------|
| 开始监控 | `monitorLocalPath()` | 监控指定路径 |
| 停止监控 | `stopMonitoringPath()` | 停止监控指定路径 |
| 变化通知 | `onChange` | 文件变化回调 |

#### 接口定义

```swift
protocol LocalFileMonitor {
    func startMonitoring(path: String)
    func stopMonitoring(path: String)
    var onChange: ((FileChangeEvent) -> Void)? { get set }
}
```

#### 监控机制

```
1. 创建文件描述符
2. 创建 DispatchSourceFileSystemObject
3. 监听写入事件
4. 事件发生时触发回调
5. 清理资源
```

#### 不负责

- ❌ 云端轮询
- ❌ 同步操作
- ❌ 事件处理（由回调处理）

---

### 模块 14: CloudFilePoller（云端文件轮询器）

**文件**: `FileMonitor.swift` (Lines 136-192)
**职责**: 轮询云端文件变化
**依赖**: `StorageClient`

#### 最小功能单元

| 功能 | 方法/属性 | 描述 |
|------|-----------|------|
| 开始轮询 | `startCloudPolling()` | 定期检查云端 |
| 停止轮询 | `stopCloudPolling()` | 停止轮询 |
| 更新 ETag | `updateKnownETag()` | 更新已知文件的 ETag |

#### 接口定义

```swift
protocol CloudFilePoller {
    func startPolling(interval: TimeInterval)
    func stopPolling()
    var onChange: ((FileChangeEvent) -> Void)? { get set }
}
```

#### 轮询机制

```
1. 获取云端文件列表
2. 比较每个文件的 ETag
3. 检测到变化时触发回调
4. 更新已知 ETag
5. 重复（按间隔）
```

#### 不负责

- ❌ 本地文件监控
- ❌ 同步操作
- ❌ 事件处理（由回调处理）

---

### 模块 15: CrossProcessNotifier（跨进程通知器）

**文件**: `FileProviderSync.swift` (Lines 18-76)
**职责**: 发送和接收跨进程通知
**依赖**: `CFNotificationCenter`

#### 最小功能单元

| 功能 | 方法/属性 | 描述 |
|------|-----------|------|
| 发送通知 | `post()` | 发送 Darwin 通知 |
| 接收通知 | `observe()` | 监听 Darwin 通知 |
| 移除监听 | `removeObserver()` | 移除通知监听器 |

#### 接口定义

```swift
protocol CrossProcessNotifier {
    func post(name: String, userInfo: [String: Any]?)
    func observe(name: String, handler: @escaping ([String: Any]?) -> Void)
    func removeObserver(name: String)
}
```

#### 通知类型

```swift
enum NotificationName: String {
    case fileChanged = "net.aabg.CloudDrive.fileChanged"
    case vaultUnlocked = "net.aabg.CloudDrive.vaultUnlocked"
    case vaultLocked = "net.aabg.CloudDrive.vaultLocked"
}
```

#### 不负责

- ❌ 通知内容处理
- ❌ 同步操作
- ❌ FileProvider 刷新

---

### 模块 16: FileProviderCoordinator（FileProvider 协调器）

**文件**: `FileProviderSync.swift` (Lines 108-189)
**职责**: 协调 FileProvider 与主应用
**依赖**: `NSFileProviderManager`, `CrossProcessNotifier`

#### 最小功能单元

| 功能 | 方法/属性 | 描述 |
|------|-----------|------|
| 通知变化 | `notifyFileChanged()` | 通知文件已变化 |
| 刷新枚举器 | `signalEnumerator()` | 刷新 FileProvider 枚举器 |
| 获取状态 | `getLastChangedFile()` | 获取最后变化的文件 |

#### 接口定义

```swift
protocol FileProviderCoordinator {
    func notifyFileChanged(vaultId: String, fileId: String)
    func notifyVaultUnlocked(vaultId: String)
    func notifyVaultLocked(vaultId: String)
    func signalEnumerator(for vaultId: String) async
}
```

#### 不负责

- ❌ 具体同步操作
- ❌ 文件传输
- ❌ 冲突解决

---

### 模块 17: SyncCoordinator（同步协调器）

**文件**: `EnhancedSyncManager.swift` (Lines 1-410)
**职责**: 协调所有同步相关操作
**依赖**: 所有其他模块

#### 最小功能单元

| 功能 | 方法/属性 | 描述 |
|------|-----------|------|
| 启动同步 | `start()` | 启动增强同步 |
| 停止同步 | `stop()` | 停止增强同步 |
| 配置同步 | `autoSyncEnabled` | 自动同步开关 |
| 统计信息 | `getSyncStatistics()` | 获取同步统计 |

#### 接口定义

```swift
protocol SyncCoordinator {
    func start()
    func stop()
    func configure(_ options: SyncOptions)
    func getStatistics() -> SyncStatistics
}

struct SyncOptions {
    var autoSyncEnabled: Bool
    var autoSyncDelay: TimeInterval
    var conflictPolicy: ConflictResolutionPolicy
}
```

#### 不负责

- ❌ 具体文件操作
- ❌ 网络请求
- ❌ 缓存管理（委托给专门模块）

---

### 模块 18: CacheCoordinator（缓存协调器）

**文件**: `EnhancedCacheManager.swift` (Lines 1-450)
**职责**: 协调缓存相关操作
**依赖**: `CacheManager`, `FileMonitor`

#### 最小功能单元

| 功能 | 方法/属性 | 描述 |
|------|-----------|------|
| 记录访问 | `recordAccess()` | 记录文件访问 |
| 预热目录 | `prefetchDirectory()` | 预热目录文件 |
| 预热文件 | `prefetchFile()` | 预热单个文件 |
| 优化策略 | `optimizeCachePolicies()` | 优化缓存策略 |

#### 接口定义

```swift
protocol CacheCoordinator {
    func recordAccess(fileId: String, type: FileAccessType)
    func prefetchDirectory(directoryId: String) async
    func prefetchFile(fileId: String) async
    func optimizePolicies() async
}
```

#### 不负责

- ❌ 缓存读写（委托给 CacheManager）
- ❌ 文件下载（委托给 FileDownloader）
- ❌ 同步操作

---

### 模块 19: StatusTracker（状态跟踪器）

**文件**: `FileStatusIndicator.swift` (Lines 1-350)
**职责**: 跟踪和报告文件状态
**依赖**: `SyncManager`, `CacheManager`, `ConflictResolver`

#### 最小功能单元

| 功能 | 方法/属性 | 描述 |
|------|-----------|------|
| 获取状态 | `getFileStatus()` | 获取文件状态 |
| 刷新状态 | `refreshStatus()` | 刷新文件状态 |
| 状态通知 | `statusChangePublisher` | 状态变化发布者 |
| 进度更新 | `setDownloadProgress()` | 更新下载进度 |

#### 接口定义

```swift
protocol StatusTracker {
    func getStatus(fileId: String) async -> FileStatus
    func refreshStatus(fileId: String) async -> FileStatus
    var statusChangePublisher: AnyPublisher<FileStatusChangeEvent, Never> { get }
}

struct FileStatus {
    let fileId: String
    let location: FileLocation
    let syncState: SyncState
    let downloadProgress: Double
    let hasConflict: Bool
    let lastUpdated: Date
}
```

#### 不负责

- ❌ 文件操作
- ❌ 同步执行
- ❌ 状态计算（委托给专门模块）

---

## 模块依赖矩阵

| 模块 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 19 |
|------|---|---|---|---|---|---|---|---|---|----|----|----|----|----|----|----|----|----|----|
| 01. NetworkMonitor |   |   |   |   |   |   |   |   |   |    |    |    |    |    |    |    |    |    |    |
| 02. MetadataStore |   |   |   |   |   |   |   |   |   |    |    |    |    |    |    |    |    |    |    |
| 03. SyncQueue |   | ✓ |   |   |   |   |   |   |   |    |    |    |    |    |    |    |    |    |    |
| 04. QueueProcessor |   |   | ✓ |   | ✓ | ✓ | ✓ |   |   |    |    |    |    |    |    |    |    |    |    |
| 05. FileUploader |   |   |   |   |   |   |   |   |   |    |    |    |    |    |    |    |    |    |    |
| 06. FileDownloader |   |   |   |   |   |   |   |   |   |    |    |    |    |    |    |    |    |    |    |
| 07. FileDeleter |   |   |   |   |   |   |   |   |   |    |    |    |    |    |    |    |    |    |    |
| 08. ConflictDetector |   | ✓ |   |   |   |   |   |   |   | ✓   |    |    |    |    |    |    |    |    |    |
| 09. ConflictResolver |   | ✓ |   |   | ✓ | ✓ |   | ✓ |   |    |    |    |    |    |    |    |    |    |    |
| 10. CacheHitDetector |   |   |   |   |   |   |   |   |   |    |    |    |    |    |    |    |    |    |    |
| 11. CacheWriter |   |   |   |   |   |   |   |   |   |    |    |    |    |    |    |    |    |    |    |
| 12. CacheCleaner |   |   |   |   |   |   |   |   |   |    |    |    |    |    |    |    |    |    |    |
| 13. LocalFileMonitor |   |   |   |   |   |   |   |   |   |    |    |    |    |    |    |    |    |    |    |
| 14. CloudFilePoller |   |   |   |   |   |   |   |   |   |   |    |    |    |    |    |    |    |    |    |    |
| 15. CrossProcessNotifier |   |   |   |   |   |   |   |   |   |   |    |    |    |    |    |    |    |    |    |    |
| 16. FileProviderCoordinator |   |   |   |   |   |   |   |   |   |   |    |    |    |    |    | ✓   |    |    |    |    |
| 17. SyncCoordinator | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |    |    |    |    |    |    |    |    |    | ✓ |
| 18. CacheCoordinator |   |   |   |   |   |   |   |   |   |   | ✓   | ✓   |    |    |    |    |    |    |    |    |
| 19. StatusTracker |   | ✓ |   |   |   |   |   | ✓ | ✓ | ✓   |    |    |    |    |    |    |    |    |    |

**说明**: ✓ 表示模块依赖（行依赖列）

---

## 总结

### 模块统计

- **总模块数**: 19
- **基础设施层**: 3 (NetworkMonitor, MetadataStore, QueueStore)
- **队列管理层**: 2 (SyncQueue, QueueProcessor)
- **同步操作层**: 3 (FileUploader, FileDownloader, FileDeleter)
- **冲突解决层**: 2 (ConflictDetector, ConflictResolver)
- **缓存管理层**: 3 (CacheHitDetector, CacheWriter, CacheCleaner)
- **文件监控层**: 2 (LocalFileMonitor, CloudFilePoller)
- **通知协调层**: 2 (CrossProcessNotifier, FileProviderCoordinator)
- **高层协调层**: 3 (SyncCoordinator, CacheCoordinator, StatusTracker)

### 最小功能原则验证

| 原则 | 验证结果 |
|------|---------|
| 单一职责 | ✅ 所有模块只负责一个功能 |
| 高内聚 | ✅ 模块内部功能紧密相关 |
| 低耦合 | ✅ 模块间依赖最小化 |
| 可替换 | ✅ 所有模块基于协议定义 |
| 可测试 | ✅ 最小功能单元易于测试 |

---

**文档结束**
