
# CloudDrive 完整流程验证

## 验证时间
2025-12-28 13:50 (UTC+8)

---

## 流程概述

```
用户操作
    ↓
1. 连接 WebDAV
    ↓
2. 初始化数据库
    ↓
3. 列出文件（显示云朵图标）
    ↓
4. 用户点击文件
    ↓
5. 检查缓存
    ├─ 缓存命中 → 直接打开
    └─ 缓存未命中 → 下载文件
        ↓
    6. 从 WebDAV 下载
        ↓
    7. 保存到缓存
        ↓
    8. 更新元数据
        ↓
    9. 云朵图标消失
        ↓
    10. 打开文件
```

---

## 1. WebDAV 连接流程

### 文件位置
- [`WebDAVClient.swift`](CloudDriveCore/WebDAVClient.swift)
- [`VirtualFileSystem.swift`](CloudDriveCore/VirtualFileSystem.swift)

### 流程步骤

#### 1.1 配置 WebDAV
```swift
// VirtualFileSystem.swift
public func configureWebDAV(baseURL: URL, username: String, password: String) {
    WebDAVClient.shared.configure(baseURL: baseURL, username: username, password: password)
    self.storageClient = .webdav
}
```

#### 1.2 测试连接
```swift
// WebDAVClient.swift
public func testConnection() async throws -> Bool {
    // 使用 PROPFIND 测试根目录访问
    // 返回 true 表示连接成功
}
```

#### 1.3 日志记录
- ✅ 连接成功/失败记录到 `webdav-YYYY-MM-DD.log`
- ✅ 认证信息（不包含密码）

### 验证点
- [ ] WebDAV 配置正确保存
- [ ] 连接测试成功
- [ ] 日志文件创建并记录连接信息

---

## 2. 数据库初始化流程

### 文件位置
- [`VFSDatabase.swift`](CloudDriveCore/VFSDatabase.swift)
- [`VirtualFileSystem.swift`](CloudDriveCore/VirtualFileSystem.swift)

### 流程步骤

#### 2.1 初始化数据库
```swift
// VirtualFileSystem.swift
public func initializeDirectMappingVault(vaultId: String, storagePath: String) async throws {
    self.currentVaultId = vaultId
    self.currentStoragePath = storagePath
    
    // 初始化数据库
    try database.initialize()
}
```

#### 2.2 创建表结构
```swift
// VFSDatabase.swift
CREATE TABLE IF NOT EXISTS files (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    parent_id TEXT NOT NULL,
    is_directory INTEGER NOT NULL,
    size INTEGER,
    modified_at REAL,
    created_at REAL
)
```

#### 2.3 日志记录
- ✅ 数据库初始化记录到 `database-YYYY-MM-DD.log`
- ✅ 表创建成功/失败

### 验证点
- [ ] 数据库文件创建在正确位置
- [ ] 表结构正确
- [ ] 日志记录数据库操作

---

## 3. 文件列表流程

### 文件位置
- [`VirtualFileSystem.swift`](CloudDriveCore/VirtualFileSystem.swift:583)
- [`WebDAVClient.swift`](CloudDriveCore/WebDAVClient.swift:96)
- [`FileProviderExtension.swift`](CloudDriveFileProvider/FileProviderExtension.swift:641)

### 流程步骤

#### 3.1 列出目录
```swift
// VirtualFileSystem.swift
public func listDirectory(directoryId: String) throws -> [VirtualFileItem] {
    // 从 WebDAV 获取文件列表
    let resources = try await listDirectoryFromWebDAV(path: directoryId)
    
    // 转换为 VirtualFileItem
    return resources.map { resource in
        VirtualFileItem(
            id: resource.path,  // 完整路径作为 ID
            name: resource.displayName,
            parentId: directoryId,
            isDirectory: resource.isDirectory,
            size: resource.contentLength,
            modifiedAt: resource.lastModified
        )
    }
}
```

#### 3.2 WebDAV PROPFIND
```swift
// WebDAVClient.swift
public func listDirectory(path: String) async throws -> [WebDAVResource] {
    // 发送 PROPFIND 请求
    // 解析 XML 响应
    // 返回资源列表
}
```

#### 3.3 FileProvider 枚举
```swift
// FileProviderExtension.swift
func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
    let vfsItems = try vfs.listDirectory(directoryId: directoryId)
    let items = vfsItems.map { File