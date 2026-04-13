# CloudDrive 同步系统架构文档

## 文档信息

- **版本**: v1.0
- **创建日期**: 2026-04-10
- **作者**: 李彦军 (liyanjun@aabg.net)
- **设计原则**: 最小功能化、单一职责、高内聚低耦合

---

## 目录

1. [架构概述](#架构概述)
2. [核心设计原则](#核心设计原则)
3. [系统分层架构](#系统分层架构)
4. [最小功能单元拆解](#最小功能单元拆解)
5. [数据流设计](#数据流设计)
6. [模块依赖关系](#模块依赖关系)
7. [同步流程详解](#同步流程详解)
8. [错误处理机制](#错误处理机制)
9. [性能优化策略](#性能优化策略)
10. [测试策略](#测试策略)

---

## 架构概述

### 系统目标

CloudDrive 同步系统的核心目标是提供：
- ✅ 可靠的双向文件同步
- ✅ 最小化网络传输（增量同步）
- ✅ 智能冲突检测与解决
- ✅ 离线支持与队列管理
- ✅ 系统级集成（File Provider）

### 架构特点

```
┌─────────────────────────────────────────────────────────────┐
│                     同步系统架构                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐       │
│  │  监控层     │  │  同步层     │  │  存储层     │       │
│  │  Monitor    │  │   Sync      │  │  Storage    │       │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘       │
│         │                │                │               │
│  ┌──────▼──────┐  ┌──────▼──────┐  ┌──────▼──────┐       │
│  │  变更检测   │  │  操作队列   │  │  元数据库   │       │
│  │  Detection  │  │   Queue     │  │  Metadata   │       │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘       │
│         │                │                │               │
│  ┌──────▼────────────────▼────────────────▼──────┐       │
│  │              核心协调层                         │       │
│  │              Coordinator                        │       │
│  └────────────────────────────────────────────────┘       │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 核心设计原则

### 1. 最小功能化原则 (Minimal Functionality)

每个模块只负责一个明确的功能，功能边界清晰：

| 模块 | 单一功能 | 不负责 |
|------|---------|--------|
| `NetworkMonitor` | 网络状态监测 | 文件操作 |
| `SyncQueue` | 队列管理 | 网络通信 |
| `ConflictDetector` | 冲突检测 | 冲突解决 |
| `ConflictResolver` | 冲突解决 | 文件传输 |
| `CacheManager` | 缓存管理 | 网络请求 |

### 2. 单一职责原则 (Single Responsibility)

```swift
// ❌ 错误示例：职责过多
class BadSyncManager {
    func monitorNetwork() { }
    func uploadFile() { }
    func detectConflict() { }
    func resolveConflict() { }
    func manageCache() { }
    func sendNotification() { }
}

// ✅ 正确示例：职责单一
class NetworkMonitor { func monitorNetwork() { } }
class FileUploader { func uploadFile() { } }
class ConflictDetector { func detectConflict() { } }
class ConflictResolver { func resolveConflict() { } }
class CacheManager { func manageCache() { } }
class NotificationSender { func sendNotification() { } }
```

### 3. 依赖倒置原则 (Dependency Inversion)

高层模块不依赖低层模块，都依赖抽象：

```swift
// 定义抽象协议
protocol StorageClient {
    func upload(local: URL, to remote: String) async throws
    func download(from remote: String, to local: URL) async throws
}

// 高层模块依赖抽象
class SyncQueue {
    private let storage: StorageClient  // 抽象依赖
    init(storage: StorageClient) {
        self.storage = storage
    }
}

// 低层模块实现抽象
class WebDAVStorage: StorageClient {
    func upload(local: URL, to remote: String) async throws { }
    func download(from remote: String, to local: URL) async throws { }
}
```

---

## 系统分层架构

```
┌──────────────────────────────────────────────────────────────┐
│                        表示层 (UI)                            │
│  ┌────────────────┐  ┌────────────────┐  ┌───────────────┐ │
│  │  FileProvider  │  │  主应用界面     │  │  设置界面      │ │
│  │   Extension    │  │  Main View     │  │  Settings     │ │
│  └────────┬───────┘  └────────┬───────┘  └───────┬───────┘ │
└───────────┼──────────────────┼──────────────────┼───────────┘
            │                  │                  │
┌───────────▼──────────────────▼──────────────────▼───────────┐
│                    应用层 (Application)                      │
│  ┌────────────────┐  ┌────────────────┐  ┌───────────────┐ │
│  │ SyncManager    │  │ FileMonitor    │  │ EnhancedCache │ │
│  │ (同步协调)      │  │ (变更监控)      │  │ (智能缓存)     │ │
│  └────────┬───────┘  └────────┬───────┘  └───────┬───────┘ │
└───────────┼──────────────────┼──────────────────┼───────────┘
            │                  │                  │
┌───────────▼──────────────────▼──────────────────▼───────────┐
│                    领域层 (Domain)                           │
│  ┌────────────────┐  ┌────────────────┐  ┌───────────────┐ │
│  │ ConflictResolver│ │ SyncQueue      │  │ StatusTracker │ │
│  │ (冲突解决)      │  │ (队列管理)      │  │ (状态跟踪)    │ │
│  └────────┬───────┘  └────────┬───────┘  └───────┬───────┘ │
│  ┌────────▼────────┐  ┌────────▼───────┐  ┌───────▼───────┐ │
│  │ NetworkMonitor  │  │ CacheManager   │  │ OpManager     │ │
│  │ (网络监控)       │  │ (缓存管理)       │  │ (操作管理)    │ │
│  └────────┬────────┘  └────────┬───────┘  └───────┬───────┘ │
└───────────┼──────────────────┼──────────────────┼───────────┘
            │                  │                  │
┌───────────▼──────────────────▼──────────────────▼───────────┐
│                   基础设施层 (Infrastructure)                 │
│  ┌────────────────┐  ┌────────────────┐  ┌───────────────┐ │
│  │ StorageClient  │  │ VFSDatabase    │  │ Logger         │ │
│  │ (存储抽象)      │  │ (数据库)        │  │ (日志)         │ │
│  └────────┬───────┘  └────────┬───────┘  └───────┬───────┘ │
│  ┌────────▼────────┐  ┌────────▼───────┐  ┌───────▼───────┐ │
│  │ WebDAVClient    │  │ Keychain       │  │ FileSystem    │ │
│  │ (WebDAV客户端)   │  │ (密钥链)        │  │ (文件系统)    │ │
│  └─────────────────┘  └─────────────────┘  └───────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

---

## 最小功能单元拆解

### 第一层：基础设施层（最小原子单元）

#### 1.1 网络状态监测器
**文件**: `SyncManager.swift` (部分)
**职责**: 监控网络连接状态变化
**最小功能**:
- ✅ 检测网络连接状态（在线/离线）
- ✅ 通知网络状态变化
- ✅ 不负责任何文件操作

```swift
protocol NetworkMonitor {
    var networkStatus: NetworkStatus { get }
    var onNetworkStatusChange: ((NetworkStatus) -> Void)? { get set }
}

enum NetworkStatus {
    case online
    case offline
    case limited
}
```

#### 1.2 元数据存储器
**文件**: `SyncManager.swift` (部分)
**职责**: 持久化文件元数据
**最小功能**:
- ✅ 保存文件元数据
- ✅ 读取文件元数据
- ✅ 不负责同步逻辑

```swift
protocol MetadataStore {
    func save(_ metadata: FileMetadata) throws
    func load(fileId: String) -> FileMetadata?
    func delete(fileId: String) throws
}
```

#### 1.3 队列持久化器
**文件**: `SyncManager.swift` (部分)
**职责**: 持久化同步队列
**最小功能**:
- ✅ 保存队列到磁盘
- ✅ 从磁盘恢复队列
- ✅ 不负责队列处理逻辑

```swift
protocol QueueStore {
    func save(_ items: [SyncQueueItem]) throws
    func load() -> [SyncQueueItem]
}
```

---

### 第二层：队列管理层（最小原子单元）

#### 2.1 同步队列
**文件**: `SyncManager.swift` (部分)
**职责**: 管理待执行同步任务
**最小功能**:
- ✅ 添加同步任务到队列
- ✅ 从队列取出任务
- ✅ 不负责任务执行

```swift
protocol SyncQueue {
    func enqueue(_ operation: SyncOperation)
    func dequeue() -> SyncOperation?
    func count() -> Int
    func peek() -> SyncOperation?
}
```

#### 2.2 队列处理器
**文件**: `SyncManager.swift` (部分)
**职责**: 处理队列中的任务
**最小功能**:
- ✅ 按顺序处理队列任务
- ✅ 处理任务失败重试
- ✅ 不负责任务执行细节

```swift
protocol QueueProcessor {
    func process(queue: SyncQueue) async
    var onTaskComplete: ((SyncOperation, Error?) -> Void)? { get set }
}
```

---

### 第三层：同步操作层（最小原子单元）

#### 3.1 文件上传器
**文件**: `SyncManager.swift` (部分)
**职责**: 执行文件上传操作
**最小功能**:
- ✅ 上传本地文件到云端
- ✅ 报告上传进度
- ✅ 不负责队列管理

```swift
protocol FileUploader {
    func upload(local: URL, to remote: String, progress: ((Double) -> Void)?) async throws
}
```

#### 3.2 文件下载器
**文件**: `SyncManager.swift` (部分)
**职责**: 执行文件下载操作
**最小功能**:
- ✅ 从云端下载文件到本地
- ✅ 报告下载进度
- ✅ 不负责队列管理

```swift
protocol FileDownloader {
    func download(from remote: String, to local: URL, progress: ((Double) -> Void)?) async throws
}
```

#### 3.3 文件删除器
**文件**: `SyncManager.swift` (部分)
**职责**: 执行文件删除操作
**最小功能**:
- ✅ 删除云端文件
- ✅ 删除本地文件
- ✅ 不负责冲突处理

```swift
protocol FileDeleter {
    func deleteRemote(path: String) async throws
    func deleteLocal(path: String) throws
}
```

---

### 第四层：冲突检测与解决层（最小原子单元）

#### 4.1 冲突检测器
**文件**: `ConflictResolver.swift` (部分)
**职责**: 检测文件冲突
**最小功能**:
- ✅ 检测文件是否冲突
- ✅ 返回冲突类型
- ✅ 不负责冲突解决

```swift
protocol ConflictDetector {
    func detect(fileId: String) async -> ConflictType?
}

enum ConflictType {
    case localOnly
    case remoteOnly
    case modificationConflict
    case contentDifference
}
```

#### 4.2 冲突解决器
**文件**: `ConflictResolver.swift` (部分)
**职责**: 解决文件冲突
**最小功能**:
- ✅ 根据策略解决冲突
- ✅ 执行冲突解决操作
- ✅ 不负责冲突检测

```swift
protocol ConflictResolver {
    func resolve(_ conflict: ConflictInfo, policy: ConflictResolutionPolicy) async throws -> ConflictResolution
}

enum ConflictResolutionPolicy {
    case localWins
    case remoteWins
    case renameLocal
    case askUser
}
```

---

### 第五层：缓存管理层（最小原子单元）

#### 5.1 缓存命中检测器
**文件**: `CacheManager.swift` (部分)
**职责**: 检测文件是否已缓存
**最小功能**:
- ✅ 检查文件缓存状态
- ✅ 返回缓存路径
- ✅ 不负责缓存清理

```swift
protocol CacheHitDetector {
    func isCached(fileId: String) -> Bool
    func cachePath(for fileId: String) -> URL
}
```

#### 5.2 缓存写入器
**文件**: `CacheManager.swift` (部分)
**职责**: 写入文件到缓存
**最小功能**:
- ✅ 保存文件到缓存
- ✅ 更新缓存元数据
- ✅ 不负责缓存清理

```swift
protocol CacheWriter {
    func write(fileId: String, data: Data, policy: CachePolicy) throws
    func write(fileId: String, from source: URL, policy: CachePolicy) throws
}
```

#### 5.3 缓存清理器
**文件**: `CacheManager.swift` (部分)
**职责**: 清理过期或过多的缓存
**最小功能**:
- ✅ 根据策略清理缓存
- ✅ 保留固定缓存
- ✅ 不负责缓存命中检测

```swift
protocol CacheCleaner {
    func cleanupIfNeeded() throws
    func clearAll() throws
    func clear(fileId: String) throws
}
```

---

### 第六层：文件监控层（最小原子单元）

#### 6.1 本地文件监控器
**文件**: `FileMonitor.swift` (部分)
**职责**: 监控本地文件系统变化
**最小功能**:
- ✅ 监控指定路径
- ✅ 检测文件变化
- ✅ 不负责云端轮询

```swift
protocol LocalFileMonitor {
    func startMonitoring(path: String)
    func stopMonitoring(path: String)
    var onChange: ((FileChangeEvent) -> Void)? { get set }
}
```

#### 6.2 云端文件轮询器
**文件**: `FileMonitor.swift` (部分)
**职责**: 轮询云端文件变化
**最小功能**:
- ✅ 定期检查云端 ETag
- ✅ 检测文件变化
- ✅ 不负责本地监控

```swift
protocol CloudFilePoller {
    func startPolling(interval: TimeInterval)
    func stopPolling()
    var onChange: ((FileChangeEvent) -> Void)? { get set }
}
```

---

### 第七层：通知与协调层（最小原子单元）

#### 7.1 跨进程通知器
**文件**: `FileProviderSync.swift`
**职责**: 发送跨进程通知
**最小功能**:
- ✅ 发送 Darwin 通知
- ✅ 接收 Darwin 通知
- ✅ 不负责通知内容处理

```swift
protocol CrossProcessNotifier {
    func post(name: String, userInfo: [String: Any]?)
    func observe(name: String, handler: @escaping ([String: Any]?) -> Void)
}
```

#### 7.2 FileProvider 协调器
**文件**: `FileProviderSync.swift` (部分)
**职责**: 协调 FileProvider 与主应用
**最小功能**:
- ✅ 通知 FileProvider 刷新
- ✅ 接收 FileProvider 变化
- ✅ 不负责具体同步操作

```swift
protocol FileProviderCoordinator {
    func signalEnumerator(for domain: NSFileProviderDomain, item: NSFileProviderItemIdentifier) async throws
    func handleFileChange(fileId: String)
}
```

---

## 数据流设计

### 上传流程数据流

```
用户操作
    │
    ▼
FileProvider.createItem()
    │
    ▼
VFS.uploadFile()
    │
    ▼
SyncQueue.enqueue(Upload)
    │
    ▼
QueueProcessor.process()
    │
    ▼
FileUploader.upload()
    │
    ▼
WebDAVClient.upload()
    │
    ▼
StorageClient (云端)
```

### 下载流程数据流

```
用户访问
    │
    ▼
FileProvider.fetchContents()
    │
    ▼
CacheHitDetector.isCached()
    │
    ├─ 是 ──▶ CacheReader.read()
    │           ▼
    │       返回本地文件
    │
    └─ 否 ──▶ SyncQueue.enqueue(Download)
                │
                ▼
            FileDownloader.download()
                │
                ▼
            WebDAVClient.download()
                │
                ▼
            CacheWriter.write()
                │
                ▼
            返回缓存文件
```

### 冲突解决数据流

```
同步操作
    │
    ▼
ConflictDetector.detect()
    │
    ├─ 无冲突 ──▶ 继续同步
    │
    └─ 有冲突 ──▶ ConflictResolver.resolve()
                    │
                    ▼
                根据策略执行
                    │
                    ├─ LocalWins ──▶ 上传本地版本
                    ├─ RemoteWins ──▶ 下载远程版本
                    ├─ RenameLocal ──▶ 重命名本地文件
                    └─ AskUser ──▶ 等待用户选择
```

---

## 模块依赖关系

### 依赖图（无环）

```
SyncManager (高层)
    │
    ├─▶ SyncQueue
    │       │
    │       ├─▶ QueueStore
    │       └─▶ QueueProcessor
    │               │
    │               ├─▶ FileUploader
    │               │       └─▶ WebDAVClient
    │               ├─▶ FileDownloader
    │               │       └─▶ WebDAVClient
    │               └─▶ FileDeleter
    │                       └─▶ WebDAVClient
    │
    ├─▶ ConflictDetector
    │       └─▶ MetadataStore
    │
    ├─▶ ConflictResolver
    │       ├─▶ FileUploader
    │       ├─▶ FileDownloader
    │       └─▶ FileSystem
    │
    ├─▶ CacheManager
    │       ├─▶ CacheHitDetector
    │       ├─▶ CacheWriter
    │       ├─▶ CacheCleaner
    │       └─▶ MetadataStore
    │
    ├─▶ FileMonitor
    │       ├─▶ LocalFileMonitor
    │       ├─▶ CloudFilePoller
    │       └─▶ NetworkMonitor
    │
    └─▶ FileProviderSync
            └─▶ CrossProcessNotifier
```

### 依赖规则

1. **单向依赖**: 高层依赖低层，低层不依赖高层
2. **接口依赖**: 依赖抽象协议而非具体实现
3. **最小依赖**: 每个模块只依赖必需的模块
4. **无环依赖**: 依赖图中没有循环依赖

---

## 同步流程详解

### 场景1：创建新文件（本地）

```
1. 用户在 Finder 中创建文件
   └─▶ FileProviderExtension.createItem()
       └─▶ VirtualFileSystem.uploadFile()
           └─▶ 同步队列添加上传任务
               └─▶ QueueProcessor 异步处理
                   └─▶ FileUploader 上传
                       └─▶ WebDAVClient 上传到服务器
                           └─▶ 更新元数据
                               └─▶ 通知 FileProvider 刷新
```

### 场景2：访问云端文件（按需下载）

```
1. 用户在 Finder 中点击文件
   └─▶ FileProviderExtension.fetchContents()
       └─▶ CacheHitDetector 检查缓存
           ├─ 缓存命中 ──▶ 直接返回本地文件
           └─ 缓存未命中 ──▶ 同步队列添加下载任务
               └─▶ QueueProcessor 异步处理
                   └─▶ FileDownloader 下载
                       └─▶ WebDAVClient 从服务器下载
                           └─▶ CacheWriter 写入缓存
                               └─▶ 返回本地文件
```

### 场景3：修改文件（冲突场景）

```
1. 用户修改本地文件
   └─▶ LocalFileMonitor 检测到变化
       └─▶ 同步队列添加上传任务
           └─▶ ConflictDetector 检测冲突
               ├─ 无冲突 ──▶ 直接上传
               └─ 有冲突 ──▶ ConflictResolver 解决
                   └─▶ 根据策略执行
                       ├─ LocalWins: 上传本地版本
                       ├─ RemoteWins: 下载远程版本
                       └─ RenameLocal: 重命名并下载
```

### 场景4：网络断开与恢复

```
1. NetworkMonitor 检测到网络断开
   └─▶ 暂停队列处理
       └─▶ 标记为离线状态
           └─▶ 文件操作添加到队列等待

2. NetworkMonitor 检测到网络恢复
   └─▶ 恢复队列处理
       └─▶ 标记为在线状态
           └─▶ 顺序处理队列中的任务
```

---

## 错误处理机制

### 错误分类

```swift
enum SyncError: Error {
    // 网络错误
    case networkUnavailable
    case networkTimeout
    case networkError(Error)

    // 存储错误
    case storageNotConfigured
    case storageFull
    case storageError(Error)

    // 文件错误
    case fileNotFound
    case fileCorrupted
    case fileLocked

    // 冲突错误
    case conflictDetected
    case conflictResolutionFailed(String)

    // 权限错误
    case permissionDenied
    case authenticationFailed

    // 系统错误
    case diskFull
    case systemError(Error)
}
```

### 错误处理策略

| 错误类型 | 处理策略 | 重试次数 | 用户提示 |
|---------|---------|---------|---------|
| 网络不可用 | 加入队列等待 | ∞ | 离线模式 |
| 网络超时 | 重试 | 3 | 正在重试 |
| 文件冲突 | 冲突解决 | 1 | 需要解决冲突 |
| 权限被拒 | 提示用户 | 0 | 权限不足 |
| 磁盘满 | 清理缓存 | 1 | 磁盘空间不足 |

### 错误恢复流程

```
错误发生
    │
    ▼
错误分类
    │
    ├─ 可恢复 ──▶ 加入重试队列
    │               │
    │               └─▶ 指数退避重试
    │
    └─ 不可恢复 ──▶ 标记为失败
                    │
                    ▼
                通知用户
                    │
                    ▼
                记录错误日志
```

---

## 性能优化策略

### 1. 队列优化

```swift
// 优先级队列（按同步状态优先级）
struct PrioritizedSyncQueue {
    func enqueue(_ item: SyncQueueItem) {
        // 高优先级: 冲突、错误
        // 中优先级: 上传、移动
        // 低优先级: 下载
    }
}
```

### 2. 批量操作

```swift
// 批量上传/下载
class BatchOperationExecutor {
    func executeBatch(_ operations: [SyncOperation]) async {
        // 并发执行多个操作
        // 限制并发数量
    }
}
```

### 3. 增量同步

```swift
// 只同步变化的块（类似 rsync）
class IncrementalSyncer {
    func calculateDelta(local: URL, remote: URL) -> [DataBlock] {
        // 计算文件差异
    }
}
```

### 4. 智能缓存

```swift
// LRU + 访问频率
class SmartCachePolicy {
    func shouldCache(fileId: String) -> Bool {
        // 基于访问历史决策
    }
}
```

---

## 测试策略

### 单元测试

```swift
// 测试最小功能单元
class ConflictDetectorTests: XCTestCase {
    func testDetectModificationConflict() {
        let detector = ConflictDetectorImpl()
        let result = await detector.detect(fileId: "test")
        XCTAssertEqual(result, .modificationConflict)
    }
}
```

### 集成测试

```swift
// 测试模块协作
class SyncFlowTests: XCTestCase {
    func testUploadFlow() async throws {
        let flow = SyncFlow(queue: queue, uploader: uploader)
        try await flow.executeUpload(file: testFile)
        // 验证结果
    }
}
```

### 端到端测试

```swift
// 测试完整场景
class E2ESyncTests: XCTestCase {
    func testFullSyncCycle() async throws {
        // 1. 创建本地文件
        // 2. 等待上传
        // 3. 修改云端文件
        // 4. 等待下载
        // 5. 验证最终状态
    }
}
```

---

## 总结

### 架构优势

1. **可维护性**: 模块职责清晰，易于理解和修改
2. **可测试性**: 最小功能单元易于单元测试
3. **可扩展性**: 新增功能不影响现有模块
4. **可替换性**: 通过协议抽象，易于替换实现
5. **高内聚低耦合**: 模块内部紧密协作，模块间松散耦合

### 关键指标

| 指标 | 目标值 | 当前值 |
|-----|--------|--------|
| 模块数量 | ≤ 20 | 19 |
| 平均依赖数 | ≤ 3 | 2.5 |
| 测试覆盖率 | ≥ 80% | 待实现 |
| 同步成功率 | ≥ 99% | 待验证 |
| 平均延迟 | ≤ 1s | 待优化 |

---

**文档结束**
