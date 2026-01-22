# 文件下载 404 错误修复 - 完整分析

## 问题分析

### 日志显示的关键信息

```
Task <357E4C1D-2050-4D6D-9A43-738474C20CA0>.<105> received response, status 207  ✅ PROPFIND 成功
Task <3C393B76-1A7E-4842-A0ED-025B2572BB49>.<106> received response, status 404  ❌ GET 失败
```

### 根本原因

**问题不在缓存策略，而在文件路径映射**：

1. **PROPFIND（列出目录）成功** - 返回 207 Multi-Status
   - 能够列出文件：`开发组周工作总结及计划2025.07.21-2025.07.24.xlsx`
   
2. **GET（下载文件）失败** - 返回 404 Not Found
   - 下载时使用的路径不正确

## 问题流程追踪

### 1. 列出目录（成功）

在 [`listDirectoryFromWebDAV()`](CloudDriveCore/VirtualFileSystem.swift:584) 中：

```swift
// 转换为 VirtualFileItem
return resources.map { resource in
    VirtualFileItem(
        id: resource.displayName,  // ✅ 使用文件名作为 ID
        name: resource.displayName,
        isDirectory: resource.isDirectory,
        size: resource.contentLength,
        modifiedAt: resource.lastModified ?? Date(),
        parentId: directoryId
    )
}
```

**结果**：文件 ID = `开发组周工作总结及计划2025.07.21-2025.07.24.xlsx`

### 2. 下载文件（失败）

在 [`fetchContents()`](CloudDriveFileProvider/FileProviderExtension.swift:215) 中：

```swift
let fileId = itemIdentifier.rawValue  // = "开发组周工作总结及计划2025.07.21-2025.07.24.xlsx"
try await self.vfs.downloadFile(fileId: fileId, to: localURL)
```

在 [`downloadFile()`](CloudDriveCore/VirtualFileSystem.swift:757) 中：

```swift
// 1. 尝试从数据库获取（失败 - 数据库中没有记录）
if let file = try? self.database.getFile(id: fileId) {
    // 不会执行
}

// 2. 尝试直接映射模式
let rootPath: String
if let root = try? self.database.getDirectory(id: "ROOT") {
    rootPath = root.remotePath  // 例如："/dav"
} else {
    rootPath = "/"
}

let remotePath = "\(rootPath)/\(fileId)"
// 结果："/dav/开发组周工作总结及计划2025.07.21-2025.07.24.xlsx"
```

### 3. 问题所在

**可能的原因**：

1. **根目录路径不正确**
   - 数据库中的 ROOT 路径可能是 `/dav` 或其他路径
   - 但实际文件在 WebDAV 根目录 `/`

2. **文件路径编码问题**
   - 中文文件名可能需要 URL 编码
   - WebDAV 客户端可能没有正确处理编码

3. **数据库未同步**
   - `listDirectoryFromWebDAV` 获取文件列表后没有同步到数据库
   - 导致下载时找不到文件的完整路径信息

## 解决方案

### 方案 1：同步文件信息到数据库（推荐）

修改 [`listDirectoryFromWebDAV()`](CloudDriveCore/VirtualFileSystem.swift:584)，在返回文件列表前同步到数据库：

```swift
private func listDirectoryFromWebDAV(directoryId: String) throws -> [VirtualFileItem] {
    // ... 获取 WebDAV 文件列表 ...
    
    // 转换为 VirtualFileItem 并同步到数据库
    let items = resources.map { resource in
        let item = VirtualFileItem(
            id: resource.displayName,
            name: resource.displayName,
            isDirectory: resource.isDirectory,
            size: resource.contentLength,
            modifiedAt: resource.lastModified ?? Date(),
            parentId: directoryId
        )
        
        // 同步到数据库
        if !resource.isDirectory {
            let fullPath = "\(remotePath)/\(resource.displayName)"
            try? database.insertFile(
                id: resource.displayName,
                name: resource.displayName,
                parentId: directoryId,
                size: resource.contentLength,
                encryptedName: resource.displayName,
                remotePath: fullPath
            )
        }
        
        return item
    }
    
    return items
}
```

### 方案 2：修复路径构建逻辑

在 [`downloadFile()`](CloudDriveCore/VirtualFileSystem.swift:757) 中，使用正确的路径：

```swift
// 2. 如果数据库中没有，尝试从父目录路径构建
print("⚠️ VFS: 数据库中未找到文件，尝试构建路径")

// 获取根目录的实际远程路径
let rootPath: String
if let root = try? self.database.getDirectory(id: "ROOT") {
    rootPath = root.remotePath
    print("   根目录路径（从数据库）: \(rootPath)")
} else {
    // 如果数据库中没有，使用 WebDAV 根目录
    rootPath = ""
    print("   使用 WebDAV 根目录")
}

// 构建完整路径（注意处理路径分隔符）
let remotePath: String
if rootPath.isEmpty || rootPath == "/" {
    remotePath = "/\(fileId)"
} else {
    remotePath = "\(rootPath)/\(fileId)"
}

print("   尝试远程路径: \(remotePath)")
```

### 方案 3：URL 编码处理

在 [`WebDAVClient.downloadFile()`](CloudDriveCore/WebDAVClient.swift:148) 中添加 URL 编码：

```swift
public func downloadFile(path: String, to destinationURL: URL, progress: @escaping (Double) -> Void) async throws {
    guard let baseURL = baseURL else {
        throw WebDAVError.notConfigured
    }
    
    // URL 编码路径（处理中文等特殊字符）
    let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    let url = baseURL.appendingPathComponent(encodedPath)
    
    print("📡 WebDAV: 下载文件")
    print("   原始路径: \(path)")
    print("   编码路径: \(encodedPath)")
    print("   完整 URL: \(url.absoluteString)")
    
    // ... 继续下载 ...
}
```

## 已实施的修复

### 1. 增强日志输出

在 [`FileProviderExtension.fetchContents()`](CloudDriveFileProvider/FileProviderExtension.swift:215) 中添加详细日志：

```swift
NSLog("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
NSLog("⬇️ FileProvider.fetchContents: 开始")
NSLog("   Item ID: \(itemIdentifier.rawValue)")
NSLog("   Calling vfs.downloadFile(fileId: \(fileId), to: \(localURL.path))")
NSLog("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
```

### 2. 改进错误处理

在 [`VirtualFileSystem.downloadFile()`](CloudDriveCore/VirtualFileSystem.swift:757) 中：

```swift
// 提供更详细的错误信息
if let webdavError = error as? WebDAVError,
   case .serverError(let statusCode) = webdavError,
   statusCode == 404 {
    print("🔴 VFS: 文件在远程服务器不存在 (404)")
    print("   提示: 文件可能已被删除或路径不正确")
    print("   文件ID: \(fileId)")
    print("   尝试的路径: \(remotePath)")
}
```

## 下一步调试

运行应用并查看完整日志，确认：

1. **文件 ID 是什么**
   ```
   📝 FileProvider: File ID to download: ???
   ```

2. **构建的远程路径是什么**
   ```
   🔍 VFS: 尝试从数据库获取文件信息...
   ⚠️ VFS: 数据库中未找到文件
   根目录路径: ???
   尝试远程路径: ???
   ```

3. **WebDAV 请求的完整 URL**
   ```
   📡 WebDAV: 下载文件
   完整 URL: ???
   ```

4. **404 错误的具体原因**
   - 路径不存在？
   - 编码问题？
   - 权限问题？

## 测试命令

```bash
# 查看 FileProvider 日志
log stream --predicate 'subsystem == "net.aabg.CloudDrive" OR processImagePath CONTAINS "CloudDriveFileProvider"' --level debug

# 测试 WebDAV 文件访问
curl -u username:password "http://webdav-server/开发组周工作总结及计划2025.07.21-2025.07.24.xlsx"

# 测试 URL 编码
curl -u username:password "http://webdav-server/%E5%BC%80%E5%8F%91%E7%BB%84%E5%91%A8%E5%B7%A5%E4%BD%9C%E6%80%BB%E7%BB%93%E5%8F%8A%E8%AE%A1%E5%88%922025.07.21-2025.07.24.xlsx"
```

## 相关文件

- [`FileProviderExtension.swift:215`](CloudDriveFileProvider/FileProviderExtension.swift:215) - fetchContents 方法
- [`VirtualFileSystem.swift:584`](CloudDriveCore/VirtualFileSystem.swift:584) - listDirectoryFromWebDAV 方法
- [`VirtualFileSystem.swift:757`](CloudDriveCore/VirtualFileSystem.swift:757) - downloadFile 方法
- [`WebDAVClient.swift:148`](CloudDriveCore/WebDAVClient.swift:148) - downloadFile 方法

## 总结

问题的核心是：
- ✅ **能列出文件**（PROPFIND 成功）
- ❌ **不能下载文件**（GET 失败 404）
- 🔍 **需要确认路径构建逻辑**

最可能的原因：
1. 数据库中没有文件的完整路径信息
2. 根目录路径配置不正确
3. URL 编码问题（中文文件名）

建议优先实施**方案 1**（同步到数据库），这样可以确保文件路径信息完整且准确。