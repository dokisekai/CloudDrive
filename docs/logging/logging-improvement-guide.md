# 日志系统改进指南

## 当前问题

从用户反馈和代码分析发现：
1. ✅ **系统日志正常** - 使用了 `logInfo(.system, ...)` 
2. ✅ **缓存日志正常** - 使用了 `logInfo(.cache, ...)`
3. ❌ **文件操作日志缺失** - 大量使用 `print()` 而不是 `logInfo(.fileOps, ...)`

## 问题根源

在 [`VirtualFileSystem.swift`](CloudDriveCore/VirtualFileSystem.swift:1) 中，所有文件操作都使用 `print()` 输出：

```swift
// ❌ 当前代码
print("📂 VFS: listDirectory 被调用 - directoryId: \(directoryId)")
print("✅ VFS: 获取到 \(resources.count) 个项目")
print("⬇️ VFS.downloadFile: 开始下载")
```

这些 `print()` 输出：
- ✅ 在 Xcode 控制台可见
- ❌ 不会记录到文件日志
- ❌ 不会记录到系统日志（Console.app）
- ❌ 无法用 `log stream` 查看

## 解决方案

### 方案 1: 快速修复（推荐）

将关键的文件操作 `print()` 替换为日志系统调用：

```swift
// ✅ 改进后的代码
logInfo(.fileOps, "listDirectory 被调用 - directoryId: \(directoryId)")
logInfo(.fileOps, "获取到 \(resources.count) 个项目")
logInfo(.fileOps, "开始下载文件")
```

### 方案 2: 保留 print() 同时添加日志

如果想保留现有的 `print()` 用于快速调试，可以同时添加日志：

```swift
print("📂 VFS: listDirectory 被调用")
logInfo(.fileOps, "listDirectory 被调用 - directoryId: \(directoryId)")
```

## 需要修改的关键位置

### 1. VirtualFileSystem.swift - 文件列表操作

**位置**: 第 556-663 行

```swift
// 当前
print("📂 VFS: listDirectory 被调用 - directoryId: \(directoryId)")
print("✅ VFS: 获取到 \(resources.count) 个项目")

// 改为
logInfo(.fileOps, "listDirectory 被调用 - directoryId: \(directoryId)")
logInfo(.fileOps, "获取到 \(resources.count) 个项目")
```

### 2. VirtualFileSystem.swift - 文件下载操作

**位置**: 第 780-834 行

```swift
// 当前
print("⬇️ VFS.downloadFile: 开始下载（直接映射模式）")
print("✅ VFS: 文件下载完成")

// 改为
logInfo(.fileOps, "开始下载文件 - ID: \(fileId)")
logSuccess(.fileOps, "文件下载完成 - 目标: \(destinationURL.path)")
```

### 3. VirtualFileSystem.swift - 文件上传操作

**位置**: 第 707-777 行

```swift
// 当前
print("⬆️ VFS: 开始上传文件（无加密模式）")
print("✅ VFS: 文件上传成功")

// 改为
logInfo(.fileOps, "开始上传文件 - 名称: \(name)")
logSuccess(.fileOps, "文件上传成功 - 远程路径: \(remoteFilePath)")
```

### 4. VirtualFileSystem.swift - 文件删除操作

**位置**: 第 837-890 行

```swift
// 当前
print("🗑️ VFS.delete: 开始删除")
print("✅ VFS: 文件删除成功")

// 改为
logInfo(.fileOps, "开始删除项目 - ID: \(itemId)")
logSuccess(.fileOps, "项目删除成功")
```

### 5. VirtualFileSystem.swift - 目录创建操作

**位置**: 第 666-704 行

```swift
// 当前
print("📁 VFS: 创建目录（无加密）: \(remotePath)")
print("✅ VFS: 目录创建成功（无加密模式）")

// 改为
logInfo(.fileOps, "创建目录 - 名称: \(name), 路径: \(remotePath)")
logSuccess(.fileOps, "目录创建成功")
```

## 修改步骤

### 步骤 1: 添加导入

确保文件顶部已导入日志系统（已存在）：

```swift
import Foundation
import CryptoKit
// Logger 通过 CloudDriveCore 模块自动可用
```

### 步骤 2: 批量替换

可以使用以下正则表达式进行批量替换：

**查找**:
```regex
print\("(📂|📁|📄|⬇️|⬆️|🗑️|✅|❌) VFS: (.+?)"\)
```

**替换为**:
```swift
logInfo(.fileOps, "$2")
```

### 步骤 3: 手动调整

批量替换后，需要手动调整：
1. 成功消息使用 `logSuccess(.fileOps, ...)`
2. 错误消息使用 `logError(.fileOps, ...)`
3. 警告消息使用 `logWarning(.fileOps, ...)`

## 测试验证

修改后，在 Xcode 中运行应用并执行文件操作：

### 1. 在 Xcode 控制台查看

```
[FILE-OPERATIONS] [2025-12-28T06:00:00Z] [ℹ️ INFO] listDirectory 被调用 - directoryId: ROOT
[FILE-OPERATIONS] [2025-12-28T06:00:01Z] [ℹ️ INFO] 获取到 8 个项目
[FILE-OPERATIONS] [2025-12-28T06:00:02Z] [ℹ️ INFO] 开始下载文件 - ID: /test.txt
[FILE-OPERATIONS] [2025-12-28T06:00:03Z] [✅ SUCCESS] 文件下载完成
```

### 2. 使用日志查看工具

```bash
./view_logs.sh
# 选择 7 - 实时监控 Xcode 运行日志
# 或选择 9 - 实时监控文件操作日志
```

### 3. 查看文件日志

```bash
tail -f ~/.CloudDrive/Logs/file-operations-*.log
```

### 4. 使用系统日志

```bash
log stream --predicate 'subsystem == "net.aabg.CloudDrive" AND category == "file-operations"' --level debug
```

## 预期效果

修改后，所有文件操作都会：
1. ✅ 在 Xcode 控制台实时显示
2. ✅ 记录到文件日志 `~/.CloudDrive/Logs/file-operations-*.log`
3. ✅ 记录到系统日志（可用 Console.app 查看）
4. ✅ 可用 `log stream` 实时监控

## 其他需要改进的文件

### WebDAVClient.swift
- 网络请求日志应使用 `logInfo(.webdav, ...)`
- HTTP 错误应使用 `logError(.webdav, ...)`

### StorageClient.swift
- 文件操作应使用 `logInfo(.fileOps, ...)`

### VFSDatabase.swift
- 数据库操作应使用 `logInfo(.database, ...)`
- SQL 错误应使用 `logError(.database, ...)`

## 最佳实践

1. **使用正确的日志类别**
   - 文件操作 → `.fileOps`
   - 网络请求 → `.webdav`
   - 数据库操作 → `.database`
   - 缓存操作 → `.cache`
   - 系统事件 → `.system`

2. **使用正确的日志级别**
   - 开始操作 → `logInfo()`
   - 成功完成 → `logSuccess()`
   - 警告信息 → `logWarning()`
   - 错误信息 → `logError()`
   - 调试信息 → `logDebug()`

3. **提供足够的上下文**
   ```swift
   // ❌ 不好
   logInfo(.fileOps, "开始下载")
   
   // ✅ 好
   logInfo(.fileOps, "开始下载文件 - ID: \(fileId), 大小: \(size) 字节")
   ```

4. **避免敏感信息**
   ```swift
   // ❌ 不要记录密码
   logInfo(.system, "密码: \(password)")
   
   // ✅ 只记录非敏感信息
   logInfo(.system, "用户认证成功 - 用户名: \(username)")
   ```

## 总结

当前日志系统已经完善，只需要将代码中的 `print()` 替换为相应的日志调用即可。这样就能在 Xcode 运行时实时看到所有文件操作日志，同时也会记录到文件和系统日志中，方便调试和问题追踪。