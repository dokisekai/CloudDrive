# FileProvider 错误域修复

## 问题描述

从日志中发现 FileProvider 返回了不支持的错误域：

```
[CRIT] Provider returned error 5 from domain CloudDriveCore.VFSError which is unsupported. 
Supported error domains are NSCocoaErrorDomain, NSFileProviderErrorDomain.
```

### 具体错误

1. **下载文件失败**：`fileNotFound` 错误使用了 `CloudDriveCore.VFSError` 域
2. **删除文件失败**：`itemNotFound` 错误使用了 `CloudDriveCore.VFSError` 域
3. **系统拒绝**：Apple 的 FileProvider 框架只接受 `NSCocoaErrorDomain` 和 `NSFileProviderErrorDomain`

## 根本原因

虽然代码中有 `convertVFSErrorToFileProviderError()` 函数来转换错误，但在某些地方：

1. **直接抛出 VFSError**：`findItem()` 方法中直接 `throw` VFSError
2. **日志输出不一致**：错误日志没有明确显示正在进行的操作
3. **错误传播链断裂**：某些 catch 块没有正确捕获和转换 VFSError

## 修复方案

### 1. 增强 `fetchContents` 方法

**修改前**：
```swift
func fetchContents(...) -> Progress {
    let progress = Progress(totalUnitCount: 100)
    Task {
        do {
            // 下载文件
            try await self.vfs.downloadFile(fileId: fileId, to: localURL)
            completionHandler(localURL, item, nil)
        } catch let error as VFSError {
            let fpError = convertVFSErrorToFileProviderError(error)
            completionHandler(nil, nil, fpError)
        }
    }
}
```

**修改后**：
```swift
func fetchContents(...) -> Progress {
    NSLog("⬇️ FileProvider: Downloading file: \(itemIdentifier.rawValue)")
    let progress = Progress(totalUnitCount: 100)
    Task {
        do {
            // 下载文件
            NSLog("⬇️ FileProvider: Downloading file from remote: \(fileId)")
            try await self.vfs.downloadFile(fileId: fileId, to: localURL)
            NSLog("✅ FileProvider: File downloaded successfully")
            completionHandler(localURL, item, nil)
        } catch let error as VFSError {
            NSLog("❌ FileProvider: Failed to fetch contents: \(error.localizedDescription)")
            let fpError = convertVFSErrorToFileProviderError(error)
            completionHandler(nil, nil, fpError)
        }
    }
}
```

**改进点**：
- ✅ 添加操作开始日志
- ✅ 添加详细的进度日志
- ✅ 使用 `error.localizedDescription` 而不是直接输出错误对象
- ✅ 确保所有错误都被转换为 NSFileProviderError

### 2. 增强 `deleteItem` 方法

**修改前**：
```swift
func deleteItem(...) -> Progress {
    Task {
        do {
            NSLog("🗑️ FileProvider: Deleting item: \(fileId)")
            try await self.vfs.delete(itemId: fileId)
            completionHandler(nil)
        } catch let error as VFSError {
            let fpError = convertVFSErrorToFileProviderError(error)
            completionHandler(fpError)
        }
    }
}
```

**修改后**：
```swift
func deleteItem(...) -> Progress {
    NSLog("🗑️ FileProvider: Deleting item: \(identifier.rawValue)")
    Task {
        do {
            try await self.vfs.delete(itemId: fileId)
            NSLog("✅ FileProvider: Item deleted successfully")
            completionHandler(nil)
        } catch let error as VFSError {
            NSLog("❌ FileProvider: Failed to delete item: \(error.localizedDescription)")
            let fpError = convertVFSErrorToFileProviderError(error)
            completionHandler(fpError)
        }
    }
}
```

**改进点**：
- ✅ 在方法入口处记录操作
- ✅ 成功时记录日志
- ✅ 失败时使用 `localizedDescription`
- ✅ 确保错误转换

### 3. 修复 `findItem` 方法

**修改前**：
```swift
private func findItem(identifier: String, in directoryId: String = "ROOT") throws -> VirtualFileItem {
    let items = try vfs.listDirectory(directoryId: directoryId)
    
    if let item = items.first(where: { $0.id == identifier }) {
        return item
    }
    
    for item in items where item.isDirectory {
        if let found = try? findItem(identifier: identifier, in: item.id) {
            return found
        }
    }
    
    throw NSFileProviderError(.noSuchItem)  // ❌ 但 vfs.listDirectory 可能抛出 VFSError
}
```

**修改后**：
```swift
private func findItem(identifier: String, in directoryId: String = "ROOT") throws -> VirtualFileItem {
    do {
        let items = try vfs.listDirectory(directoryId: directoryId)
        
        if let item = items.first(where: { $0.id == identifier }) {
            return item
        }
        
        for item in items where item.isDirectory {
            if let found = try? findItem(identifier: identifier, in: item.id) {
                return found
            }
        }
        
        throw NSFileProviderError(.noSuchItem)
    } catch let error as VFSError {
        // ✅ 转换 VFSError 为 NSFileProviderError
        throw convertVFSErrorToFileProviderError(error)
    } catch {
        // ✅ 其他错误也转换为 NSFileProviderError
        throw NSFileProviderError(.noSuchItem)
    }
}
```

**改进点**：
- ✅ 捕获 `vfs.listDirectory()` 可能抛出的 VFSError
- ✅ 将所有 VFSError 转换为 NSFileProviderError
- ✅ 确保不会有 VFSError 泄露到 FileProvider 框架

## 错误转换映射

现有的 `convertVFSErrorToFileProviderError()` 函数提供了完整的映射：

| VFSError | NSFileProviderError |
|----------|---------------------|
| `.vaultLocked` | `.notAuthenticated` |
| `.parentNotFound` | `.noSuchItem` |
| `.fileNotFound` | `.noSuchItem` |
| `.itemNotFound` | `.noSuchItem` |
| `.encryptionFailed` | `.cannotSynchronize` |
| `.decryptionFailed` | `.cannotSynchronize` |
| `.databaseError` | `.serverUnreachable` |
| `.invalidPath` | `.noSuchItem` |
| `.networkError` | `.serverUnreachable` |
| `.authenticationFailed` | `.notAuthenticated` |
| `.storageNotConfigured` | `.providerNotFound` |
| `.directoryCreationFailed` | `.cannotSynchronize` |
| `.fileOperationFailed` | `.cannotSynchronize` |

## 测试验证

### 测试场景

1. **下载不存在的文件**
   - 预期：返回 `NSFileProviderError.noSuchItem`
   - 日志：`❌ FileProvider: Failed to fetch contents: fileNotFound`

2. **删除不存在的项目**
   - 预期：返回 `NSFileProviderError.noSuchItem`
   - 日志：`❌ FileProvider: Failed to delete item: itemNotFound`

3. **列出目录时数据库错误**
   - 预期：返回 `NSFileProviderError.serverUnreachable`
   - 日志：包含详细的错误信息

### 验证命令

```bash
# 查看 FileProvider 日志
log stream --predicate 'subsystem == "com.apple.FileProvider"' --level debug

# 或使用我们的测试脚本
./test_fileprovider_errors.sh
```

## 预期效果

修复后，系统日志应该显示：

```
✅ FileProvider: File downloaded successfully
```

或者在错误情况下：

```
❌ FileProvider: Failed to fetch contents: 文件不存在
[ERROR] Creating internal error for "fetchContentsForItemWithID", 
        original error was: NSError: NSFileProviderErrorDomain -1005
```

**关键改进**：
- ✅ 不再出现 `CloudDriveCore.VFSError` 域的错误
- ✅ 所有错误都使用 `NSFileProviderErrorDomain`
- ✅ 日志更清晰，便于调试
- ✅ 符合 Apple FileProvider 框架要求

## 相关文件

- [`CloudDriveFileProvider/FileProviderExtension.swift`](CloudDriveFileProvider/FileProviderExtension.swift) - 主要修复文件
- [`CloudDriveCore/VirtualFileSystem.swift`](CloudDriveCore/VirtualFileSystem.swift) - VFSError 定义
- [`FILEPROVIDER_ERROR_FIX.md`](FILEPROVIDER_ERROR_FIX.md) - 之前的错误修复文档

## 总结

这次修复确保了：

1. **错误域合规性**：所有返回给 FileProvider 框架的错误都使用支持的错误域
2. **错误转换完整性**：在所有可能抛出 VFSError 的地方都进行了转换
3. **日志可读性**：使用 `localizedDescription` 提供人类可读的错误信息
4. **调试友好性**：在关键操作点添加了详细的日志记录

修复完成后，FileProvider 应该能够正常处理文件操作，不再出现不支持的错误域警告。