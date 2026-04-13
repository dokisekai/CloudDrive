# iCloud 风格功能实现总结

## 概述

本次实现为 CloudDrive 项目添加了完整的 iCloud 风格功能，包括文件变更监控、双向自动同步、智能冲突解决、缓存优化和文件状态指示器。

## 已实现的功能模块

### 1. FileMonitor - 文件变更监控

**文件**: `CloudDriveCore/FileMonitor.swift`

**功能特性**:
- ✅ 本地文件系统监控（使用 DispatchSourceFileSystemObject）
- ✅ 云端文件轮询（定期检查 ETag 变化）
- ✅ 文件变化检测和通知
- ✅ 支持文件和目录监控
- ✅ 可配置的轮询间隔（默认 30 秒）

**主要 API**:
```swift
// 启动/停止监控
FileMonitor.shared.startMonitoring()
FileMonitor.shared.stopMonitoring()

// 监控本地路径
FileMonitor.shared.monitorLocalPath("/path/to/directory")
FileMonitor.shared.stopMonitoringPath("/path/to/directory")

// 监听文件变化
FileMonitor.shared.onChange = { event in
    print("文件变化: \(event.description)")
}

// 更新已知文件的 ETag
FileMonitor.shared.updateKnownETag("/file/path", etag: "new-etag-value")
```

**集成要点**:
1. 在应用启动时调用 `startMonitoring()`
2. 设置 `onChange` 回调来处理文件变化事件
3. 文件变化会自动触发 EnhancedSyncManager 的同步流程

---

### 2. EnhancedSyncManager - 增强同步管理器

**文件**: `CloudDriveCore/EnhancedSyncManager.swift`

**功能特性**:
- ✅ 双向自动同步（本地 ↔ 云端）
- ✅ 增量同步（只同步变化的文件）
- ✅ 智能冲突解决（支持多种策略）
- ✅ 延迟同步（避免频繁同步）
- ✅ 后台同步任务
- ✅ 同步统计和监控

**主要 API**:
```swift
// 启动/停止增强同步
EnhancedSyncManager.shared.start()
EnhancedSyncManager.shared.stop()

// 配置自动同步
EnhancedSyncManager.shared.autoSyncEnabled = true
EnhancedSyncManager.shared.autoSyncDelay = 2.0  // 变更后2秒开始同步

// 配置冲突解决策略
EnhancedSyncManager.shared.conflictResolutionPolicy = .localWins
// 可选策略: .localWins, .remoteWins, .renameLocal, .askUser

// 获取同步统计
let stats = EnhancedSyncManager.shared.getSyncStatistics()
print("同步操作数: \(stats.totalSyncOperations)")
print("成功率: \(stats.syncRate * 100)%")
```

**同步流程**:
1. FileMonitor 检测到文件变化
2. 延迟 `autoSyncDelay` 秒（避免频繁触发）
3. 根据变化类型执行相应同步操作：
   - 文件创建/修改：上传到云端或下载到本地
   - 文件删除：同步删除到另一端
   - 目录变化：递归同步目录内容
4. 自动检测和解决冲突
5. 更新同步统计

---

### 3. ConflictResolver - 文件冲突解决器

**文件**: `CloudDriveCore/ConflictResolver.swift`

**功能特性**:
- ✅ 智能冲突检测（基于修改时间和内容差异）
- ✅ 多种冲突解决策略
- ✅ 冲突历史记录
- ✅ 自定义文件级别的解决策略
- ✅ 批量冲突检测

**冲突类型**:
- `.localOnly` - 仅本地存在
- `.remoteOnly` - 仅云端存在
- `.modificationConflict` - 修改冲突（两端都被修改）
- `.contentDifference` - 内容差异

**解决策略**:
- `.localWins` - 本地优先，上传到云端
- `.remoteWins` - 云端优先，下载到本地
- `.renameLocal` - 重命名本地文件（添加冲突标记）
- `.askUser` - 询问用户（需要 UI 支持）

**主要 API**:
```swift
// 检测单个文件冲突
let conflict = await ConflictResolver.shared.detectConflict(fileId: "/file/path")
if let conflict = conflict {
    print("检测到冲突: \(conflict.conflictType)")
}

// 批量检测冲突
let conflicts = await ConflictResolver.shared.detectAllConflicts()
print("发现 \(conflicts.count) 个冲突")

// 解决冲突
let resolution = try await ConflictResolver.shared.resolveConflict(conflict!)
print("冲突已解决: \(resolution.details)")

// 配置默认策略
ConflictResolver.shared.setDefaultResolutionPolicy(.localWins)

// 配置文件级别的策略
ConflictResolver.shared.setResolutionPolicy(
    for: "/specific/file.txt",
    policy: .remoteWins
)

// 获取冲突历史
let history = ConflictResolver.shared.getConflictHistory(limit: 50)
for record in history {
    print("冲突记录: \(record.fileId) - \(record.resolution.action)")
}
```

**集成要点**:
1. EnhancedSyncManager 会自动调用 ConflictResolver
2. 默认策略设置为 `.askUser` 需要实现 UI 对话框
3. 建议在应用设置中提供冲突解决策略选项

---

### 4. EnhancedCacheManager - 增强缓存管理器

**文件**: `CloudDriveCore/EnhancedCacheManager.swift`

**功能特性**:
- ✅ 智能缓存预热（预测用户需要访问的文件）
- ✅ 访问频率优化（根据访问模式调整缓存策略）
- ✅ 自适应缓存管理
- ✅ 后台优化任务
- ✅ 访问模式学习
- ✅ 文件预取机制

**缓存策略**:
- `.pinned` - 固定缓存（高频文件）
- `.automatic` - 自动管理（偶尔访问的文件）
- `.temporary` - 临时缓存（稀有访问的文件）

**访问频率**:
- `.frequent` - 频繁访问（24小时内访问3次以上）
- `.occasional` - 偶尔访问
- `.rare` - 稀有访问
- `.unknown` - 未知

**主要 API**:
```swift
// 记录文件访问
EnhancedCacheManager.shared.recordAccess(
    fileId: "/file/path",
    accessType: .read  // 或 .write
)

// 获取访问频率
let frequency = EnhancedCacheManager.shared.getAccessFrequency(fileId: "/file/path")

// 预热目录
await EnhancedCacheManager.shared.prefetchDirectory(directoryId: "/folder")

// 预热单个文件
await EnhancedCacheManager.shared.prefetchFile(fileId: "/file/path")

// 取消预热
EnhancedCacheManager.shared.cancelPrefetch(fileId: "/file/path")

// 配置选项
EnhancedCacheManager.shared.enableSmartPrefetch = true
EnhancedCacheManager.shared.enableAccessFrequencyOptimization = true
EnhancedCacheManager.shared.prefetchConcurrency = 3

// 获取缓存统计
let stats = EnhancedCacheManager.shared.getEnhancedStatistics()
print("总大小: \(stats.totalSize) 字节")
print("高频文件数: \(stats.frequentAccessCount)")
print("固定文件数: \(stats.pinnedFileCount)")
```

**智能预热策略**:
1. 同一目录的文件（根据时间相关性）
2. 高频访问的文件
3. 小文件优先（减少带宽消耗）
4. 根据访问历史预测下一步操作

---

### 5. FileStatusIndicator - 文件状态指示器

**文件**: `CloudDriveCore/FileStatusIndicator.swift`

**功能特性**:
- ✅ 实时文件状态查询
- ✅ 状态变化通知（使用 Combine）
- ✅ 下载进度跟踪
- ✅ 状态缓存和刷新
- ✅ 批量状态查询

**文件位置**:
- `.local` - 仅本地
- `.cloud` - 仅云端
- `.both` - 本地和云端
- `.unknown` - 未知

**同步状态**:
- `.synced` - 已同步 ✅
- `.downloading` - 下载中 ⬇️
- `.uploading` - 上传中 ⬆️
- `.pendingDownload` - 待下载 🌐
- `.pendingUpload` - 待上传 📤
- `.syncing` - 同步中 🔄
- `.conflict` - 冲突 ⚠️
- `.error` - 错误 ❌

**主要 API**:
```swift
// 获取文件状态
let status = await FileStatusIndicator.shared.getFileStatus(fileId: "/file/path")
print("状态: \(status.syncState)")
print("位置: \(status.location)")
print("图标: \(status.iconEmoji)")

// 获取文件状态（同步）
let status = FileStatusIndicator.shared.getFileStatusSync(fileId: "/file/path")

// 批量获取状态
let statuses = await FileStatusIndicator.shared.getFileStatuses(
    fileIds: ["/file1", "/file2", "/file3"]
)

// 监听状态变化（使用 Combine）
FileStatusIndicator.shared.statusChangePublisher
    .sink { event in
        print("文件状态变化: \(event.description)")
    }
    .store(in: &cancellables)

// 刷新状态
await FileStatusIndicator.shared.refreshStatus(fileId: "/file/path")

// 批量刷新状态
await FileStatusIndicator.shared.refreshAllStatuses(fileIds: ["/file1", "/file2"])

// 设置下载进度
FileStatusIndicator.shared.setDownloadProgress(fileId: "/file/path", progress: 0.5)

// 启用/禁用实时更新
FileStatusIndicator.shared.setRealTimeUpdateEnabled(true)
```

**FileProviderItem 集成**:
```swift
extension FileProviderItem {
    // 获取状态图标
    let icon = fileProviderItem.statusIcon  // 返回: "✅", "⬇️", "🌐", etc.

    // 获取状态描述
    let description = fileProviderItem.statusDescription

    // 获取下载进度
    let progress = fileProviderItem.downloadProgress
}
```

---

## 集成指南

### 1. 初始化流程

在应用启动时（如 `AppDelegate.applicationDidFinishLaunching` 或主应用的 `init`）：

```swift
// 1. 启动文件监控
FileMonitor.shared.startMonitoring()

// 2. 启动增强同步
EnhancedSyncManager.shared.start()

// 3. 可选：配置同步参数
EnhancedSyncManager.shared.autoSyncEnabled = true
EnhancedSyncManager.shared.autoSyncDelay = 2.0

// 4. 可选：配置冲突解决策略
ConflictResolver.shared.setDefaultResolutionPolicy(.localWins)
```

### 2. FileProviderExtension 集成

在 `FileProviderExtension.swift` 的 `init` 方法中：

```swift
// 初始化增强同步管理器
EnhancedSyncManager.shared.start()

// 配置缓存管理器
if let vaultId = vaultInfo?.id {
    // 预热根目录
    Task {
        await EnhancedCacheManager.shared.prefetchDirectory(directoryId: "/")
    }
}
```

在文件操作回调中记录访问：

```swift
// 在 fetchContents 成功后
EnhancedCacheManager.shared.recordAccess(
    fileId: itemIdentifier.rawValue,
    accessType: .read
)
```

### 3. Xcode 项目配置

将新文件添加到 Xcode 项目：

1. 在 Xcode 中打开 `CloudDrive.xcodeproj`
2. 右键点击 `CloudDriveCore` 文件夹
3. 选择 "Add Files to CloudDrive..."
4. 选择以下文件：
   - `CloudDriveCore/FileMonitor.swift`
   - `CloudDriveCore/EnhancedSyncManager.swift`
   - `CloudDriveCore/ConflictResolver.swift`
   - `CloudDriveCore/EnhancedCacheManager.swift`
   - `CloudDriveCore/FileStatusIndicator.swift`
5. 确保添加到 `CloudDriveCore` target
6. 确保在 "File Inspector" 中勾选 "CloudDriveCore" target

---

## 总结

本次实现为 CloudDrive 添加了完整的 iCloud 风格功能，包括：

✅ **文件变更监控** - 实时监控本地和云端文件变化
✅ **双向自动同步** - 智能的增量同步机制
✅ **智能冲突解决** - 多种策略的冲突检测和解决
✅ **缓存优化** - 智能预热和访问频率优化
✅ **文件状态指示** - 实时的文件状态显示和通知

这些功能使 CloudDrive 能够提供接近 iCloud 的用户体验，同时保持开源和灵活的架构。

## 贡献者

- 李彦军 (liyanjun@aabg.net)

## 许可证

MIT License
