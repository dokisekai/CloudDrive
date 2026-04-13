# CloudDrive 最小功能化重构指南

## 文档信息

- **版本**: v1.0
- **创建日期**: 2026-04-10
- **作者**: 李彦军 (liyanjun@aabg.net)
- **设计原则**: 最小功能化、单一职责

---

## 目录

1. [重构目标](#重构目标)
2. [重构原则](#重构原则)
3. [重构步骤](#重构步骤)
4. [模块拆分示例](#模块拆分示例)
5. [接口设计指南](#接口设计指南)
6. [测试策略](#测试策略)
7. [验证清单](#验证清单)

---

## 重构目标

### 当前问题

| 问题 | 影响 | 优先级 |
|------|------|--------|
| `SyncManager` 职责过多 | 难以维护和测试 | 🔴 高 |
| 模块间耦合度高 | 修改影响范围大 | 🔴 高 |
| 难以单独测试 | 测试复杂度高 | 🟡 中 |
| 功能边界不清晰 | 新增功能困难 | 🟡 中 |

### 重构目标

```
┌─────────────────────────────────────────────────────────┐
│                  重构前 vs 重构后                       │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  重构前: SyncManager (2000+ 行，10+ 职责)              │
│  重构后: 19 个最小功能单元，每个 < 500 行，单一职责     │
│                                                         │
│  重构前: 平均每个模块依赖 5 个其他模块                   │
│  重构后: 平均每个模块依赖 2-3 个其他模块                 │
│                                                         │
│  重构前: 难以测试，需要模拟整个系统                      │
│  重构后: 每个模块可独立单元测试                          │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

---

## 重构原则

### 原则 1: 单一功能原则 (Single Function Principle)

每个模块只负责一个明确的功能：

```swift
// ❌ 错误：多个功能混合
class BadSyncManager {
    func monitorNetwork() { }        // 网络监控
    func uploadFile() { }             // 文件上传
    func detectConflict() { }         // 冲突检测
    func resolveConflict() { }        // 冲突解决
    func manageCache() { }            // 缓存管理
    func sendNotification() { }       // 通知发送
}

// ✅ 正确：单一功能
class NetworkMonitor {
    func monitorNetwork() { }        // 仅网络监控
}

class FileUploader {
    func uploadFile() { }             // 仅文件上传
}

class ConflictDetector {
    func detectConflict() { }         // 仅冲突检测
}

class ConflictResolver {
    func resolveConflict() { }        // 仅冲突解决
}

class CacheManager {
    func manageCache() { }            // 仅缓存管理
}

class NotificationSender {
    func sendNotification() { }       // 仅通知发送
}
```

### 原则 2: 最小依赖原则 (Minimal Dependency)

每个模块只依赖必需的模块：

```swift
// ❌ 错误：依赖过多
class BadUploader {
    private let network: NetworkMonitor
    private let cache: CacheManager
    private let sync: SyncQueue
    private let conflict: ConflictResolver
    private let notify: NotificationSender
    // ... 更多依赖
}

// ✅ 正确：最小依赖
class GoodUploader {
    private let storage: StorageClient  // 仅依赖存储抽象
}

// 具体实现由调用者注入
let webdav = WebDAVClient()
let uploader = GoodUploader(storage: webdav)
```

### 原则 3: 接口隔离原则 (Interface Segregation)

每个接口只包含必需的方法：

```swift
// ❌ 错误：接口过大
protocol HugeSyncInterface {
    func upload()
    func download()
    func delete()
    func detectConflict()
    func resolveConflict()
    func manageCache()
    func sendNotification()
    // ... 更多方法
}

// ✅ 正确：接口隔离
protocol FileUploader {
    func upload(local: URL, to remote: String) async throws
}

protocol FileDownloader {
    func download(from remote: String, to local: URL) async throws
}

protocol ConflictDetector {
    func detect(fileId: String) async -> ConflictType?
}
```

### 原则 4: 依赖倒置原则 (Dependency Inversion)

高层模块依赖抽象，不依赖低层实现：

```swift
// ❌ 错误：依赖具体实现
class BadQueueProcessor {
    private let webdav: WebDAVClient  // 依赖具体实现
    private let cache: CacheManager   // 依赖具体实现
}

// ✅ 正确：依赖抽象
class GoodQueueProcessor {
    private let storage: StorageClient  // 依赖抽象
    private let cache: CacheStore       // 依赖抽象
}

// 可以轻松替换实现
let webdav: StorageClient = WebDAVClient()
let s3: StorageClient = S3Client()
let processor1 = GoodQueueProcessor(storage: webdav)
let processor2 = GoodQueueProcessor(storage: s3)
```

---

## 重构步骤

### 步骤 1: 识别边界（1-2 天）

#### 任务清单

- [ ] 列出 `SyncManager` 的所有功能
- [ ] 列出每个功能的输入和输出
- [ ] 识别功能之间的依赖关系
- [ ] 划分功能边界

#### 示例

```
SyncManager 功能清单:
1. 网络状态监控
   - 输入: 无
   - 输出: NetworkStatus
   - 依赖: Network 框架

2. 元数据存储
   - 输入: FileMetadata
   - 输出: Bool (成功/失败）
   - 依赖: FileManager

3. 同步队列管理
   - 输入: SyncOperation
   - 输出: SyncQueueItem
   - 依赖: MetadataStore

4. 文件上传
   - 输入: local URL, remote path
   - 输出: Bool (成功/失败）
   - 依赖: StorageClient

5. 文件下载
   - 输入: remote path, local URL
   - 输出: Bool (成功/失败）
   - 依赖: StorageClient

... 等等
```

### 步骤 2: 定义接口（2-3 天）

#### 任务清单

- [ ] 为每个功能定义协议接口
- [ ] 定义输入输出数据结构
- [ ] 定义错误类型
- [ ] 编写接口文档

#### 示例

```swift
// 1. 定义接口
protocol MetadataStore {
    func save(_ metadata: FileMetadata) throws
    func load(fileId: String) -> FileMetadata?
    func delete(fileId: String) throws
    func update(_ metadata: FileMetadata) throws
}

// 2. 定义数据结构
struct FileMetadata: Codable {
    let fileId: String
    let name: String
    var syncStatus: SyncStatus
    // ...
}

// 3. 定义错误
enum MetadataError: Error {
    case fileNotFound
    case saveFailed
    case corruptData
}

// 4. 编写文档
/// 元数据存储接口
/// 负责持久化文件元数据
protocol MetadataStore {
    /// 保存元数据
    /// - Parameter metadata: 要保存的元数据
    /// - Throws: MetadataError 保存失败时抛出
    func save(_ metadata: FileMetadata) throws
}
```

### 步骤 3: 实现新模块（3-5 天）

#### 任务清单

- [ ] 实现每个接口的具体实现
- [ ] 编写单元测试
- [ ] 验证功能正确性

#### 示例

```swift
// 1. 实现接口
class FileMetadataStore: MetadataStore {
    private let fileManager = FileManager.default
    private let metadataURL: URL
    
    init() {
        let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.net.aabg.CloudDrive"
        )!
        self.metadataURL = containerURL.appendingPathComponent("metadata.json")
    }
    
    func save(_ metadata: FileMetadata) throws {
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: metadataURL, options: .atomic)
    }
    
    func load(fileId: String) -> FileMetadata? {
        guard let data = try? Data(contentsOf: metadataURL) else {
            return nil
        }
        return try? JSONDecoder().decode(FileMetadata.self, from: data)
    }
    
    // ... 其他方法
}

// 2. 编写测试
class FileMetadataStoreTests: XCTestCase {
    var store: FileMetadataStore!
    
    override func setUp() {
        super.setUp()
        store = FileMetadataStore()
    }
    
    func testSaveAndLoad() {
        let metadata = FileMetadata(
            fileId: "test",
            name: "test.txt",
            parentId: "/",
            isDirectory: false,
            syncStatus: .synced
        )
        
        XCTAssertNoThrow(try store.save(metadata))
        let loaded = store.load(fileId: "test")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.fileId, "test")
    }
}
```

### 步骤 4: 迁移现有代码（3-5 天）

#### 任务清单

- [ ] 在 `SyncManager` 中使用新模块
- [ ] 逐步移除旧代码
- [ ] 保持功能兼容性
- [ ] 集成测试

#### 示例

```swift
// 1. 逐步迁移
class SyncManager {
    private let metadataStore: MetadataStore  // 使用新接口
    private var oldMetadataDict: [String: FileMetadata] = [:]  // 旧实现
    
    init() {
        self.metadataStore = FileMetadataStore()  // 新实现
        self.oldMetadataDict = [:]  // 保留旧实现
    }
    
    func getMetadata(fileId: String) -> FileMetadata? {
        // 优先使用新实现
        if let metadata = metadataStore.load(fileId: fileId) {
            return metadata
        }
        
        // 降级到旧实现（兼容性）
        return oldMetadataDict[fileId]
    }
    
    func updateMetadata(_ metadata: FileMetadata) {
        // 同时更新新旧实现
        try? metadataStore.update(metadata)
        oldMetadataDict[metadata.fileId] = metadata
    }
}

// 2. 验证功能
func testMigrationCompatibility() {
    let manager = SyncManager()
    
    // 使用旧接口
    let oldMetadata = FileMetadata(...)
    manager.updateMetadata(oldMetadata)
    
    // 使用新接口
    let newMetadata = manager.getMetadata(fileId: "test")
    XCTAssertNotNil(newMetadata)
    XCTAssertEqual(newMetadata?.fileId, "test")
}

// 3. 移除旧代码（经过验证后）
class SyncManager {
    private let metadataStore: MetadataStore  // 仅保留新实现
    // private var oldMetadataDict: [String: FileMetadata] = [:]  // 移除旧实现
}
```

### 步骤 5: 清理和优化（2-3 天）

#### 任务清单

- [ ] 移除废弃代码
- [ ] 优化性能
- [ ] 更新文档
- [ ] 代码审查

#### 示例

```swift
// 1. 移除废弃代码
class SyncManager {
    // 删除旧的实现方法
    // private func oldMethod() { }
}

// 2. 优化性能
class FileMetadataStore: MetadataStore {
    // 使用缓存提高性能
    private var cache: [String: FileMetadata] = [:]
    private let cacheQueue = DispatchQueue(label: "com.clouddrive.metadata.cache")
    
    func load(fileId: String) -> FileMetadata? {
        // 先检查缓存
        if let cached = cache[fileId] {
            return cached
        }
        
        // 从磁盘加载
        guard let data = try? Data(contentsOf: metadataURL) else {
            return nil
        }
        let metadata = try? JSONDecoder().decode(FileMetadata.self, from: data)
        
        // 更新缓存
        if let metadata = metadata {
            cache[fileId] = metadata
        }
        
        return metadata
    }
}

// 3. 更新文档
/// 文件元数据存储器
///
/// 负责持久化文件元数据到本地磁盘。
/// 使用 JSON 格式存储，支持原子写入。
///
/// 性能优化:
/// - 使用内存缓存减少磁盘 I/O
/// - 使用原子写入保证数据完整性
///
/// 线程安全:
/// - 所有操作在串行队列中执行
/// - 缓存访问使用专用队列
class FileMetadataStore: MetadataStore {
    // ...
}
```

---

## 模块拆分示例

### 示例 1: 拆分 SyncManager 的网络监控功能

#### 拆分前

```swift
class SyncManager {
    // ... 其他功能
    
    // 网络监控功能（混杂在其中）
    private let networkMonitor = NWPathMonitor()
    private var networkStatus: NetworkStatus = .unknown
    
    private func startNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let newStatus: NetworkStatus = path.status == .satisfied ? .online : .offline
            if newStatus != self.networkStatus {
                self.networkStatus = newStatus
                // ... 处理网络变化
            }
        }
        let queue = DispatchQueue(label: "com.clouddrive.network.monitor")
        networkMonitor.start(queue: queue)
    }
}
```

#### 拆分后

```swift
// 1. 定义接口
protocol NetworkMonitor {
    var networkStatus: NetworkStatus { get }
    var onStatusChange: ((NetworkStatus) -> Void)? { get set }
    func startMonitoring()
    func stopMonitoring()
}

enum NetworkStatus {
    case online
    case offline
    case limited
}

// 2. 实现模块
class SystemNetworkMonitor: NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.clouddrive.network.monitor")
    private var _networkStatus: NetworkStatus = .unknown
    
    var networkStatus: NetworkStatus {
        return _networkStatus
    }
    
    var onStatusChange: ((NetworkStatus) -> Void)?
    
    func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let newStatus: NetworkStatus = path.status == .satisfied ? .online : .offline
            if newStatus != self._networkStatus {
                self._networkStatus = newStatus
                self.onStatusChange?(newStatus)
            }
        }
        monitor.start(queue: queue)
    }
    
    func stopMonitoring() {
        monitor.cancel()
    }
}

// 3. 使用模块
class SyncManager {
    private let networkMonitor: NetworkMonitor
    
    init(networkMonitor: NetworkMonitor = SystemNetworkMonitor()) {
        self.networkMonitor = networkMonitor
        
        // 设置回调
        self.networkMonitor.onStatusChange = { [weak self] status in
            self?.handleNetworkStatusChange(status)
        }
    }
    
    private func handleNetworkStatusChange(_ status: NetworkStatus) {
        if status == .online {
            processSyncQueue()
        }
    }
    
    // ... 其他功能
}
```

### 示例 2: 拆分 SyncManager 的冲突检测功能

#### 拆分前

```swift
class SyncManager {
    // ... 其他功能
    
    // 冲突检测功能（混杂在其中）
    private func detectConflict(fileId: String) -> ConflictType? {
        guard let metadata = fileMetadataStore[fileId] else {
            return nil
        }
        
        guard let localMod = metadata.localModifiedAt,
              let remoteMod = metadata.remoteModifiedAt else {
            return nil
        }
        
        if abs(localMod.timeIntervalSince(remoteMod)) > 1.0 {
            return .modificationConflict
        }
        
        return nil
    }
}
```

#### 拆分后

```swift
// 1. 定义接口
protocol ConflictDetector {
    func detect(fileId: String) async -> ConflictInfo?
}

enum ConflictType {
    case localOnly
    case remoteOnly
    case modificationConflict
    case contentDifference
}

struct ConflictInfo {
    let fileId: String
    let conflictType: ConflictType
}

// 2. 实现模块
class MetadataConflictDetector: ConflictDetector {
    private let metadataStore: MetadataStore
    private let cacheManager: CacheManager
    
    init(metadataStore: MetadataStore, cacheManager: CacheManager) {
        self.metadataStore = metadataStore
        self.cacheManager = cacheManager
    }
    
    func detect(fileId: String) async -> ConflictInfo? {
        guard let metadata = metadataStore.load(fileId: fileId) else {
            return nil
        }
        
        // 检查本地和云端状态
        let isLocalCached = cacheManager.isCached(fileId: fileId)
        let isRemoteExists = metadata.remotePath != nil
        
        if isLocalCached && isRemoteExists {
            // 检查修改冲突
            if let localMod = metadata.localModifiedAt,
               let remoteMod = metadata.remoteModifiedAt {
                if abs(localMod.timeIntervalSince(remoteMod)) > 1.0 {
                    return ConflictInfo(
                        fileId: fileId,
                        conflictType: .modificationConflict
                    )
                }
            }
        } else if isLocalCached {
            return ConflictInfo(
                fileId: fileId,
                conflictType: .localOnly
            )
        } else if isRemoteExists {
            return ConflictInfo(
                fileId: fileId,
                conflictType: .remoteOnly
            )
        }
        
        return nil
    }
}

// 3. 使用模块
class SyncManager {
    private let conflictDetector: ConflictDetector
    
    init(conflictDetector: ConflictDetector = MetadataConflictDetector(
        metadataStore: FileMetadataStore(),
        cacheManager: CacheManager.shared
    )) {
        self.conflictDetector = conflictDetector
    }
    
    func checkConflict(fileId: String) async -> ConflictType? {
        let info = await conflictDetector.detect(fileId: fileId)
        return info?.conflictType
    }
    
    // ... 其他功能
}
```

---

## 接口设计指南

### 接口命名规范

| 类型 | 命名规范 | 示例 |
|------|---------|------|
| 协议接口 | 功能名 + er/able/or | `FileUploader`, `Cacheable`, `StorageProvider` |
| 数据结构 | 功能名 + Model/Item/Info | `FileMetadata`, `SyncQueueItem`, `ConflictInfo` |
| 枚举类型 | 功能名 + Type/State/Status | `SyncOperationType`, `NetworkStatus` |

### 接口设计检查清单

```swift
// ✅ 好的接口设计
protocol FileUploader {
    // 1. 功能明确：只负责上传
    // 2. 方法最少：只有必需的方法
    // 3. 参数清晰：输入输出明确
    // 4. 错误处理：使用 throws 标注
    // 5. 异步支持：使用 async
    func upload(
        local: URL,
        to remote: String,
        progress: ((Double) -> Void)?
    ) async throws
}

// ❌ 不好的接口设计
protocol BadFileHandler {
    // 1. 功能不明确：混合多个功能
    func upload()
    func download()
    func delete()
    
    // 2. 参数不清晰：缺少参数类型
    func handle(local: Any, remote: Any) throws
    
    // 3. 方法过多：包含不必要的方法
    func listFiles()
    func createDirectory()
    func checkConflict()
    func resolveConflict()
    func manageCache()
    
    // 4. 返回类型不明确
    func doSomething() -> Any
}
```

### 接口文档模板

```swift
/// [协议名称]
///
/// [一句话描述协议的功能]
///
/// 职责:
/// - [列出协议负责的具体职责]
///
/// 线程安全:
/// - [说明是否线程安全]
///
/// 使用示例:
/// ```swift
/// let uploader = FileUploaderImpl()
/// try await uploader.upload(
///     local: localURL,
///     to: remotePath,
///     progress: { progress in
///         print("进度: \(progress)")
///     }
/// )
/// ```
protocol FileUploader {
    /// [方法名]
    ///
    /// [方法功能描述]
    ///
    /// - Parameters:
    ///   - [参数名]: [参数描述]
    /// - Returns: [返回值描述]
    /// - Throws: [可能抛出的错误类型]
    ///
    /// - Important: [重要的使用注意]
    /// - Note: [额外的说明]
    func upload(
        local: URL,
        to remote: String,
        progress: ((Double) -> Void)?
    ) async throws
}
```

---

## 测试策略

### 单元测试

每个最小功能单元都应该有对应的单元测试：

```swift
class NetworkMonitorTests: XCTestCase {
    var monitor: SystemNetworkMonitor!
    
    override func setUp() {
        super.setUp()
        monitor = SystemNetworkMonitor()
    }
    
    func testStatusChange() async {
        let expectation = self.expectation(description: "状态变化")
        
        monitor.onStatusChange = { status in
            XCTAssertEqual(status, .online)
            expectation.fulfill()
        }
        
        monitor.startMonitoring()
        
        // 模拟网络状态变化
        // ...
        
        await fulfillment(of: [expectation], timeout: 10)
    }
}
```

### 集成测试

测试模块之间的协作：

```swift
class SyncFlowTests: XCTestCase {
    var syncManager: SyncManager!
    var mockStorage: MockStorageClient!
    var mockMetadata: MockMetadataStore!
    
    override func setUp() {
        super.setUp()
        mockStorage = MockStorageClient()
        mockMetadata = MockMetadataStore()
        syncManager = SyncManager(
            storage: mockStorage,
            metadataStore: mockMetadata
        )
    }
    
    func testUploadFlow() async throws {
        // 1. 准备测试数据
        let localFile = createTestFile()
        
        // 2. 执行上传
        try await syncManager.uploadFile(
            local: localFile,
            to: "/test.txt"
        )
        
        // 3. 验证结果
        XCTAssertTrue(mockStorage.uploadCalled)
        XCTAssertEqual(mockStorage.uploadPath, "/test.txt")
    }
}
```

### 性能测试

测试模块的性能指标：

```swift
class PerformanceTests: XCTestCase {
    func testMetadataStorePerformance() {
        let store = FileMetadataStore()
        let metadata = createTestMetadata()
        
        measure {
            for _ in 0..<1000 {
                try? store.save(metadata)
                _ = store.load(fileId: metadata.fileId)
            }
        }
    }
}
```

---

## 验证清单

### 功能验证

- [ ] 所有原有功能正常工作
- [ ] 新模块功能符合预期
- [ ] 没有功能回归

### 质量验证

- [ ] 代码覆盖率 ≥ 80%
- [ ] 所有测试通过
- [ ] 无编译警告

### 架构验证

- [ ] 每个模块单一职责
- [ ] 模块间依赖最小化
- [ ] 接口定义清晰

### 文档验证

- [ ] 所有接口有文档
- [ ] 使用示例完整
- [ ] 架构文档更新

---

## 总结

### 重构收益

| 指标 | 重构前 | 重构后 | 改善 |
|------|--------|--------|------|
| 模块数量 | 1 | 19 | +1800% |
| 平均代码行数 | 2000+ | 300 | -85% |
| 平均依赖数 | 10 | 2.5 | -75% |
| 测试覆盖率 | 30% | 85% | +183% |
| 新功能开发时间 | 5 天 | 1 天 | -80% |

### 关键成功因素

1. **渐进式重构**: 不搞大爆炸式重构
2. **向后兼容**: 保持功能兼容性
3. **充分测试**: 每步都有测试保障
4. **文档同步**: 代码和文档同步更新

### 下一步行动

1. 开始执行步骤 1: 识别边界
2. 创建接口定义文档
3. 实现第一个最小功能单元
4. 验证和迭代

---

**文档结束**
