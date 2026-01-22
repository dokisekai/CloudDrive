# FileProvider 错误处理修复文档

## 问题分析

根据系统日志，发现以下关键错误：

### 1. 不支持的错误域 (CRITICAL)
```
[CRIT] Provider returned error 6 from domain CloudDriveCore.VFSError which is unsupported. 
Supported error domains are NSCocoaErrorDomain, NSFileProviderErrorDomain.
```

**原因**：FileProvider Extension 直接返回了 `VFSError`，但 macOS 系统只支持：
- `NSCocoaErrorDomain`
- `NSFileProviderErrorDomain`

### 2. 文件/项目未找到错误
```
❌ FileProvider: Failed to delete item: itemNotFound
❌ FileProvider: Failed to fetch contents: fileNotFound
```

**原因**：VFS 抛出的错误没有正确转换为 FileProvider 支持的错误类型。

### 3. Provider 查询失败
```
[ERROR] Cannot query for providers. Error: NSError: Cocoa 4099
```

**原因**：XPC 连接问题，可能是由于错误的错误处理导致 Extension 崩溃。

## 修复方案

### 1. 创建专用的错误转换函数

新增 [`convertVFSErrorToFileProviderError()`](CloudDriveFileProvider/FileProviderExtension.swift:468) 函数，确保所有 VFSError 都被正确转换：

```swift
fileprivate func convertVFSErrorToFileProviderError(_ vfsError: VFSError) -> NSFileProviderError {
    NSLog("🔄 FileProvider: Converting VFSError to NSFileProviderError: \(vfsError)")
    
    switch vfsError {
    case .vaultLocked:
        return NSFileProviderError(.notAuthenticated)
    case .parentNotFound:
        return NSFileProviderError(.noSuchItem)
    case .fileNotFound, .itemNotFound:
        return NSFileProviderError(.noSuchItem)
    case .encryptionFailed, .decryptionFailed:
        return NSFileProviderError(.cannotSynchronize)
    case .databaseError(let detail):
        NSLog("⚠️ FileProvider: Database error: \(detail)")
        return NSFileProviderError(.serverUnreachable)
    case .invalidPath:
        return NSFileProviderError(.noSuchItem)
    case .networkError:
        return NSFileProviderError(.serverUnreachable)
    case .authenticationFailed:
        return NSFileProviderError(.notAuthenticated)
    case .storageNotConfigured:
        return NSFileProviderError(.providerNotFound)
    case .directoryCreationFailed(let detail):
        NSLog("⚠️ FileProvider: Directory creation failed: \(detail)")
        return NSFileProviderError(.cannotSynchronize)
    case .fileOperationFailed(let detail):
        NSLog("⚠️ FileProvider: File operation failed: \(detail)")
        return NSFileProviderError(.cannotSynchronize)
    @unknown default:
        NSLog("⚠️ FileProvider: Unknown VFSError case: \(vfsError)")
        return NSFileProviderError(.serverUnreachable)
    }
}
```

### 2. 改进所有方法的错误处理

在所有 FileProvider 方法中使用类型化的错误捕获：

```swift
} catch let error as VFSError {
    NSLog("❌ FileProvider: VFSError in [method]: \(error)")
    let fpError = convertVFSErrorToFileProviderError(error)
    completionHandler(nil, fpError)
} catch let error as NSFileProviderError {
    NSLog("❌ FileProvider: NSFileProviderError in [method]: \(error)")
    completionHandler(nil, error)
} catch {
    NSLog("❌ FileProvider: Unknown error in [method]: \(error)")
    let fpError = NSFileProviderError(.serverUnreachable)
    completionHandler(nil, fpError)
}
```

### 3. 修复的方法列表

以下方法已更新错误处理：

1. [`item(for:request:completionHandler:)`](CloudDriveFileProvider/FileProviderExtension.swift:157) - 获取文件项
2. [`fetchContents(for:version:request:completionHandler:)`](CloudDriveFileProvider/FileProviderExtension.swift:206) - 获取文件内容
3. [`createItem(basedOn:fields:contents:options:request:completionHandler:)`](CloudDriveFileProvider/FileProviderExtension.swift:254) - 创建文件/目录
4. [`modifyItem(_:baseVersion:changedFields:contents:options:request:completionHandler:)`](CloudDriveFileProvider/FileProviderExtension.swift:339) - 修改文件
5. [`deleteItem(identifier:baseVersion:options:request:completionHandler:)`](CloudDriveFileProvider/FileProviderExtension.swift:395) - 删除文件/目录
6. [`enumerateItems(for:startingAt:)`](CloudDriveFileProvider/FileProviderExtension.swift:523) - 枚举目录内容

### 4. 增强的日志记录

所有错误现在都会记录详细信息：
- 错误类型（VFSError、NSFileProviderError、Unknown）
- 错误详情（包括关联值）
- 转换过程

## VFSError 到 NSFileProviderError 映射表

| VFSError | NSFileProviderError | 说明 |
|----------|---------------------|------|
| `.vaultLocked` | `.notAuthenticated` | 保险库已锁定 |
| `.parentNotFound` | `.noSuchItem` | 父目录不存在 |
| `.fileNotFound` | `.noSuchItem` | 文件不存在 |
| `.itemNotFound` | `.noSuchItem` | 项目不存在 |
| `.encryptionFailed` | `.cannotSynchronize` | 加密失败 |
| `.decryptionFailed` | `.cannotSynchronize` | 解密失败 |
| `.databaseError` | `.serverUnreachable` | 数据库错误 |
| `.invalidPath` | `.noSuchItem` | 无效路径 |
| `.networkError` | `.serverUnreachable` | 网络错误 |
| `.authenticationFailed` | `.notAuthenticated` | 认证失败 |
| `.storageNotConfigured` | `.providerNotFound` | 存储未配置 |
| `.directoryCreationFailed` | `.cannotSynchronize` | 目录创建失败 |
| `.fileOperationFailed` | `.cannotSynchronize` | 文件操作失败 |

## 预期效果

修复后应该：

1. ✅ **消除 CRIT 错误**：不再出现 "unsupported error domain" 警告
2. ✅ **正确处理文件未找到**：返回 `.noSuchItem` 而不是原始 VFSError
3. ✅ **改善稳定性**：减少 Extension 崩溃和 XPC 连接问题
4. ✅ **更好的调试信息**：详细的错误日志帮助追踪问题

## 测试建议

1. **基本操作测试**：
   - 创建文件/目录
   - 读取文件内容
   - 修改文件
   - 删除文件/目录

2. **错误场景测试**：
   - 访问不存在的文件
   - 在未解锁的保险库中操作
   - 网络断开时的操作

3. **日志监控**：
   ```bash
   log stream --predicate 'subsystem == "com.apple.FileProvider"' --level debug
   ```

## 相关文件

- [`FileProviderExtension.swift`](CloudDriveFileProvider/FileProviderExtension.swift) - 主要修复文件
- [`VirtualFileSystem.swift`](CloudDriveCore/VirtualFileSystem.swift) - VFSError 定义
- [`FileProviderItem.swift`](CloudDriveFileProvider/FileProviderItem.swift) - FileProvider Item 实现

## 注意事项

⚠️ **重要**：所有从 VFS 抛出的错误都必须在 FileProvider Extension 边界处转换为支持的错误域。永远不要让 `VFSError` 直接传递给系统的 completion handler。

## 下一步

如果问题仍然存在，检查：
1. Extension 是否正确加载
2. App Group 配置是否正确
3. Keychain 访问权限
4. WebDAV 连接状态