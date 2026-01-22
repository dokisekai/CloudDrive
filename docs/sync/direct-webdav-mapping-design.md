# 直接 WebDAV 映射设计

## 设计原则

### 1. 完全透明映射
- **文件 ID = WebDAV 路径**
- 不使用 UUID
- 不使用加密
- 不使用路径转换

### 2. 数据库角色
- **仅用于元数据缓存**（可选）
- 不存储路径映射关系
- 可以完全不依赖数据库运行

### 3. 路径示例

| WebDAV 路径 | 文件 ID | FileProvider 显示 |
|------------|---------|------------------|
| `/` | `/` | 根目录 |
| `/Documents` | `/Documents` | Documents |
| `/Documents/file.txt` | `/Documents/file.txt` | file.txt |
| `/开发组周工作总结.xlsx` | `/开发组周工作总结.xlsx` | 开发组周工作总结.xlsx |

## 数据库结构简化

### 方案 A：完全无数据库（推荐）
```swift
// 所有操作直接调用 WebDAV
// 不需要数据库
```

### 方案 B：最小化数据库（性能优化）
```sql
-- 只缓存文件列表，不存储路径映射
CREATE TABLE file_cache (
    path TEXT PRIMARY KEY,           -- WebDAV 完整路径
    name TEXT NOT NULL,              -- 文件名
    is_directory INTEGER NOT NULL,   -- 是否目录
    size INTEGER,                    -- 文件大小
    modified_at REAL,                -- 修改时间
    cached_at REAL NOT NULL,         -- 缓存时间
    expires_at REAL NOT NULL         -- 过期时间
);

CREATE INDEX idx_parent_path ON file_cache(
    substr(path, 1, length(path) - length(name) - 1)
);
```

## 核心实现

### 1. VirtualFileSystem 简化

```swift
public class VirtualFileSystem {
    private var storageClient: StorageClient?
    private var baseURL: String = "/"  // WebDAV 根路径
    
    // 列出目录 - 直接调用 WebDAV
    public func listDirectory(path: String) async throws -> [VirtualFileItem] {
        guard let storageClient = storageClient else {
            throw VFSError.storageNotConfigured
        }
        
        let resources = try await storageClient.listDirectory(path: path)
        
        return resources.map { resource in
            VirtualFileItem(
                id: resource.path,              // ✅ 使用完整路径作为 ID
                name: resource.displayName,
                isDirectory: resource.isDirectory,
                size: resource.contentLength,
                modifiedAt: resource.lastModified ?? Date(),
                parentId: parentPath(of: resource.path)
            )
        }
    }
    
    // 下载文件 - 直接使用路径
    public func downloadFile(path: String, to destinationURL: URL) async throws {
        guard let storageClient = storageClient else {
            throw VFSError.storageNotConfigured
        }
        
        // 直接下载，path 就是 WebDAV 路径
        try await storageClient.downloadFile(path: path, to: destinationURL) { _