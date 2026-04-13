# CloudDrive 核心同步逻辑 Bug 报告

## 文档信息

- **审查日期**: 2026-04-10
- **审查范围**: 核心同步逻辑（SyncManager, SyncStatus, VirtualFileSystem, FileMonitor, EnhancedSyncManager, ConflictResolver, FileStatusIndicator）
- **严重程度**: 🔴 严重 🟡 中等 🟢 轻微

---

## 🔴 严重 Bug

### Bug #1: `SyncManager.processSyncQueue()` 竞态条件 (Race Condition)

**文件**: `SyncManager.swift` 第 198-215 行

**问题**: `isProcessingQueue` 不是原子操作，在多线程环境下会产生竞态条件。

```swift
// BUG: isProcessingQueue 检查和设置不是原子操作
guard !isProcessingQueue else {
    return
}
isProcessingQueue = true  // <- 另一个线程可能在 guard 之后、这里之前进入
```

**修复方案**: 使用 actor 或加锁保护。

---

### Bug #2: `SyncManager.processQueueAsync()` 处理失败项时可能越界

**文件**: `SyncManager.swift` 第 240-254 行

**问题**: 在遍历 items 时同时修改 `syncQueueItems`，如果重试超过3次，会从 `syncQueueItems` 中移除元素，但后续第 259 行又会 `removeAll`，可能导致双重删除或索引不一致。

```swift
// BUG: 遍历 items 期间修改 syncQueueItems
for item in items {
    // ...
    syncQueue.sync {
        if let index = syncQueueItems.firstIndex(where: { $0.id == item.id }) {
            // 如果 retryCount >= 3，这里移除
            if updatedItem.retryCount >= 3 {
                syncQueueItems.remove(at: index) // 移除1
            }
        }
    }
}

// BUG: 之后又用 processedItems 移除（可能包含已删除的项）
syncQueue.sync {
    syncQueueItems.removeAll { processedItems.contains($0.id) } // 移除2（双重删除安全，但逻辑不清晰）
}
```

---

### Bug #3: `FileMetadata` 缺少 `lastSyncTime` 字段

**文件**: `SyncStatus.swift` 第 212-264 行

**问题**: `ConflictResolver` 和 `EnhancedSyncManager` 引用了 `metadata.lastSyncTime`，但 `FileMetadata` 结构体中没有定义这个字段，会导致编译错误。

```swift
// ConflictResolver.swift 第 135 行引用了不存在的字段:
let lastSyncTime = metadata.lastSyncTime ?? Date.distantPast
```

---

### Bug #4: `SyncStatus.synced` 关联值缺失

**文件**: `SyncStatus.swift` 第 16 行, `EnhancedSyncManager.swift` 第 625-630 行

**问题**: `EnhancedSyncManager` 扩展了 `SyncStatus` 尝试从 `.synced` case 提取关联值 `lastSync`，但 `SyncStatus.synced` 没有关联值。

```swift
// EnhancedSyncManager.swift 第 625-630 行
extension SyncStatus {
    var lastSyncTime: Date? {
        get {
            switch self {
            case .synced(let lastSync):  // BUG: .synced 没有关联值！
                return lastSync
            default:
                return nil
            }
        }
    }
}
```

---

### Bug #5: `FileMonitor` 使用 `DispatchSourceFileSystemObject` 监控目录时 FD 泄漏

**文件**: `FileMonitor.swift` 第 88-116 行

**问题**: 在 `monitorLocalPath` 中创建 `DispatchSource` 时，如果文件描述符打开成功但 DispatchSource 创建失败（理论上不会，但防御性编程需要），文件描述符会泄漏。

---

## 🟡 中等 Bug

### Bug #6: `EnhancedSyncManager.syncTasks` 线程不安全

**文件**: `EnhancedSyncManager.swift` 第 22 行

**问题**: `syncTasks` 是 `[String: Task]` 字典，在多个地方读写但没有同步保护。

```swift
private var syncTasks: [String: Task<Void, Never>] = [:]

// 在 setupFileMonitor 中写入:
self.syncTasks[event.path] = task

// 在 cancelAllSyncTasks 中读取:
for (path, task) in self.syncTasks { ... }
```

---

### Bug #7: `EnhancedCacheManager.prefetchTasks` 线程不安全

**文件**: `EnhancedCacheManager.swift`

**问题**: 与 Bug #6 类似，`prefetchTasks` 字典在多线程环境下没有同步保护。

---

### Bug #8: `ConflictResolver` 使用 `storageClient` 但无法访问私有属性

**文件**: `ConflictResolver.swift` 第 270-330 行

**问题**: `ConflictResolver` 通过 `syncManager.getStorageClient()` 获取存储客户端，但 `SyncManager` 中 `storageClient` 是 `private` 的，没有公开的 `getStorageClient()` 方法（只在我创建的 `FileMonitor.swift` 扩展中添加了，但这个扩展访问了私有属性）。

---

### Bug #9: `FileStatusIndicator` 扩展 `FileProviderItem` 但可能找不到类型

**文件**: `FileStatusIndicator.swift` 底部

**问题**: 扩展了 `FileProviderItem` 类型，但这个类型定义在 `CloudDriveFileProvider` 模块中，`CloudDriveCore` 模块无法直接访问。

---

### Bug #10: `EnhancedSyncManager` 的 `ConflictResolutionPolicy` 与 `ConflictResolver` 重复定义

**文件**: `EnhancedSyncManager.swift` 第 44-50 行, `ConflictResolver.swift` 第 309-314 行

**问题**: 两个文件都定义了 `ConflictResolutionPolicy` 枚举，会导致编译时重复定义错误。

---

## 🟢 轻微问题

### Issue #11: `SyncStatus` 的 `needsSync` 不包含 `error` 状态

**文件**: `SyncStatus.swift` 第 44-51 行

**问题**: `error` 状态通常意味着需要重试同步，但 `needsSync` 返回 `false`，导致错误状态的文件不会出现在待同步列表中。

### Issue #12: `SyncManager.saveMetadata()` 和 `saveSyncQueue()` 静默忽略错误

**文件**: `SyncManager.swift` 第 119-125 行

**问题**: 使用 `try?` 忽略了编码和写入错误，可能导致数据丢失而不被察觉。

### Issue #13: `FileMonitor` 轮询只检查根目录 `/`

**文件**: `FileMonitor.swift` 第 `pollCloudChanges` 方法

**问题**: 云端轮询只获取 `/` 目录的文件列表，不会递归检查子目录变化。

---

## 修复计划

按优先级排序：
1. 🔴 Bug #3 & #4: 修复 `FileMetadata` 和 `SyncStatus` 缺失字段
2. 🔴 Bug #1: 修复 `isProcessingQueue` 竞态条件
3. 🔴 Bug #10: 修复重复定义
4. 🔴 Bug #8: 修复存储客户端访问
5. 🟡 Bug #6 & #7: 添加线程安全保护
6. 🟢 其余问题

---

**文档结束**
