# 删除操作超时修复

## 问题描述

用户在删除本地文件夹时遇到问题：
- 系统一直显示"正在将移动xxx到废纸篓"
- 删除操作卡住，无法完成
- Finder 界面无响应

## 问题原因

1. **异步操作没有超时保护**
   - `deleteItem` 方法使用 `Task` 异步执行删除操作
   - 如果 WebDAV 服务器响应慢或网络问题，操作会无限期挂起
   - `completionHandler` 永远不会被调用

2. **Progress 对象未正确更新**
   - 系统等待 progress 完成信号
   - 如果操作挂起，progress 永远不会标记为完成

3. **没有错误恢复机制**
   - 一旦操作挂起，用户只能强制退出应用

## 解决方案

### 1. 添加超时保护机制

在 [`FileProviderExtension.swift`](CloudDriveFileProvider/FileProviderExtension.swift:529) 的 `deleteItem` 方法中添加了多层超时保护：

```swift
// 30秒超时保护
DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
    completionLock.lock()
    let shouldTimeout = !hasCompleted
    completionLock.unlock()
    
    if shouldTimeout {
        NSLog("⏰ FileProvider: Delete operation timed out after 30 seconds")
        logError(.fileOps, "删除操作超时（30秒）")
        safeCompletion(NSFileProviderError(.serverUnreachable))
    }
}
```

### 2. 实现安全的 Completion 包装器

确保 `completionHandler` 只被调用一次：

```swift
var hasCompleted = false
let completionLock = NSLock()

let safeCompletion: (Error?) -> Void = { error in
    completionLock.lock()
    defer { completionLock.unlock() }
    
    if !hasCompleted {
        hasCompleted = true
        progress.completedUnitCount = 1
        completionHandler(error)
    }
}
```

### 3. 添加操作级别超时

使用 `withTimeout` 辅助函数为 VFS 删除操作添加 25 秒超时：

```swift
try await withTimeout(seconds: 25) {
    try await self.vfs.delete(itemId: fileId)
}
```

### 4. 实现超时辅助函数

在文件末尾添加了通用的超时辅助函数：

```swift
func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        // 添加实际操作
        group.addTask {
            try await operation()
        }
        
        // 添加超时任务
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError("Operation timed out after \(seconds) seconds")
        }
        
        // 返回第一个完成的任务结果
        let result = try await group.next()!
        
        // 取消其他任务
        group.cancelAll()
        
        return result
    }
}
```

## 修复效果

### 修复前
- ❌ 删除操作可能永久挂起
- ❌ 用户界面无响应
- ❌ 必须强制退出应用

### 修复后
- ✅ 删除操作最多等待 30 秒
- ✅ 超时后自动返回错误
- ✅ 用户可以重试或取消操作
- ✅ 系统保持响应

## 超时层级

修复实现了两层超时保护：

1. **操作级超时（25秒）**
   - 直接包装 VFS 删除操作
   - 如果 WebDAV 请求超时，立即抛出 `TimeoutError`

2. **方法级超时（30秒）**
   - 作为最后的安全网
   - 确保即使操作级超时失败，也能返回结果

## 使用建议

### 对于用户

1. **网络问题时**
   - 如果删除操作超时，检查网络连接
   - 等待 30 秒后会自动返回错误
   - 可以重试删除操作

2. **大文件夹删除**
   - 删除包含大量文件的文件夹可能需要更长时间
   - 如果超时，可以尝试分批删除

3. **服务器响应慢**
   - 检查 WebDAV 服务器状态
   - 考虑增加超时时间（需要修改代码）

### 对于开发者

1. **调整超时时间**
   - 操作级超时：修改 `withTimeout(seconds: 25)`
   - 方法级超时：修改 `.asyncAfter(deadline: .now() + 30)`

2. **添加更多日志**
   - 超时事件已记录到日志
   - 可以通过日志分析超时原因

3. **扩展到其他操作**
   - 可以将相同的超时机制应用到其他文件操作
   - 如上传、下载、移动等

## 测试建议

### 测试场景

1. **正常删除**
   ```
   - 删除小文件 → 应该立即完成
   - 删除空文件夹 → 应该立即完成
   ```

2. **慢速网络**
   ```
   - 模拟慢速网络
   - 删除文件应该在 30 秒内返回结果（成功或超时）
   ```

3. **服务器不可达**
   ```
   - 断开 WebDAV 服务器
   - 删除操作应该在 30 秒内超时
   - 显示适当的错误消息
   ```

4. **大文件夹**
   ```
   - 删除包含多个文件的文件夹
   - 观察是否能在超时前完成
   ```

### 验证方法

```bash
# 查看删除操作日志
log stream --predicate 'subsystem == "net.aabg.CloudDrive"' --level debug | grep -i delete

# 查看超时日志
log stream --predicate 'subsystem == "net.aabg.CloudDrive"' --level debug | grep -i timeout
```

## 相关文件

- [`CloudDriveFileProvider/FileProviderExtension.swift`](CloudDriveFileProvider/FileProviderExtension.swift:529) - 删除操作实现
- [`CloudDriveCore/VirtualFileSystem.swift`](CloudDriveCore/VirtualFileSystem.swift:962) - VFS 删除逻辑
- [`CloudDriveCore/WebDAVClient.swift`](CloudDriveCore/WebDAVClient.swift:390) - WebDAV 删除请求

## 后续改进

1. **可配置超时时间**
   - 允许用户在设置中调整超时时间
   - 根据网络状况自动调整

2. **重试机制**
   - 超时后自动重试
   - 指数退避策略

3. **批量删除优化**
   - 对于大文件夹，显示进度
   - 支持取消操作

4. **更好的错误提示**
   - 区分网络超时和服务器错误
   - 提供具体的解决建议

## 总结

此修复通过添加多层超时保护，确保删除操作不会永久挂起。用户现在可以在合理的时间内得到操作结果（成功或失败），大大改善了用户体验。

**修复日期**: 2026-01-14
**影响范围**: File Provider 删除操作
**向后兼容**: 是
**需要重新编译**: 是