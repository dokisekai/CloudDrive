# 数据库完整性错误修复

## 问题描述

应用日志显示了严重的 SQLite 数据库完整性错误：

```
BUG IN CLIENT OF libsqlite3.dylib: database integrity compromised by API violation: 
vnode unlinked while in use: /Users/snz/Library/Group Containers/group.net.aabg.CloudDrive/.CloudDrive/vfs.db
invalidated open fd: 14 (0x11)
```

### 症状

1. **文件列表不显示**：虚拟盘中看不到任何文件
2. **数据库错误**：SQLite 报告文件节点在使用时被删除
3. **文件描述符失效**：打开的文件描述符变为无效

## 根本原因

在 [`VFSDatabase.swift:62`](CloudDriveCore/VFSDatabase.swift:62) 的 `initialize()` 方法中：

```swift
if FileManager.default.fileExists(atPath: dbPath.path) {
    print("⚠️ 数据库文件已存在，将重新创建")
    close()
    try? FileManager.default.removeItem(at: dbPath)  // ❌ 危险操作！
}
```

**问题**：
1. 主应用和 FileProvider Extension 共享同一个数据库文件
2. 当主应用删除数据库时，FileProvider Extension 可能仍在使用它
3. 删除正在使用的数据库文件违反了 SQLite 的使用规则
4. 导致数据库完整性错误和后续操作失败

## 修复方案

### 1. 智能数据库初始化

**修改前**：
```swift
func initialize(vaultId: String, basePath: String) throws {
    // 如果数据库已存在，先关闭并删除
    if FileManager.default.fileExists(atPath: dbPath.path) {
        print("⚠️ 数据库文件已存在，将重新创建")
        close()
        try? FileManager.default.removeItem(at: dbPath)  // ❌ 直接删除
    }
    
    try open()
    try createTables()
    try saveVaultInfo(vaultId: vaultId, basePath: basePath)
}
```

**修改后**：
```swift
func initialize(vaultId: String, basePath: String) throws {
    // 如果数据库已存在，检查是否需要重新初始化
    if FileManager.default.fileExists(atPath: dbPath.path) {
        print("ℹ️ 数据库文件已存在")
        
        // 尝试打开并验证数据库
        do {
            try open()
            
            // 检查保险库信息是否匹配
            if let info = try? getVaultInfo(), info.vaultId == vaultId {
                print("✅ 数据库已存在且保险库ID匹配，跳过初始化")
                return  // ✅ 复用现有数据库
            }
            
            // 保险库ID不匹配，需要重新初始化
            print("⚠️ 保险库ID不匹配，需要重新初始化")
            close()
            
            // ✅ 使用安全的方式删除数据库
            // 1. 先重命名旧数据库
            let backupPath = dbPath.path + ".backup.\(Date().timeIntervalSince1970)"
            try FileManager.default.moveItem(atPath: dbPath.path, toPath: backupPath)
            print("✅ 旧数据库已备份到: \(backupPath)")
            
            // 2. 稍后删除备份（给其他进程时间关闭）
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                try? FileManager.default.removeItem(atPath: backupPath)
                print("🗑️ 已删除数据库备份")
            }
            
        } catch {
            print("⚠️ 无法打开现有数据库: \(error.localizedDescription)")
            print("   将创建新数据库")
            close()
        }
    }
    
    try open()
    try createTables()
    try saveVaultInfo(vaultId: vaultId, basePath: basePath)
}
```

### 2. 修复策略

#### 策略 A：复用现有数据库（推荐）
- ✅ 检查数据库是否已存在
- ✅ 验证保险库 ID 是否匹配
- ✅ 如果匹配，直接复用，避免重新创建
- ✅ 减少数据库操作，提高性能

#### 策略 B：安全删除旧数据库
当需要重新初始化时：
1. **重命名而不是删除**：使用 `moveItem` 而不是 `removeItem`
2. **延迟删除**：给其他进程 5 秒时间关闭数据库连接
3. **备份保留**：保留备份文件名包含时间戳，便于调试

## 技术细节

### 为什么不能直接删除？

SQLite 数据库文件的特点：
1. **文件锁定**：打开的数据库会持有文件锁
2. **多进程访问**：主应用和扩展可能同时访问
3. **文件描述符**：删除文件会使打开的 fd 失效
4. **完整性检查**：SQLite 会检测文件节点变化

### 重命名 vs 删除

| 操作 | 效果 | 风险 |
|------|------|------|
| `removeItem` | 立即删除文件 | ❌ 其他进程的 fd 失效 |
| `moveItem` | 重命名文件 | ✅ 其他进程仍可访问旧文件 |

### 延迟删除的原因

```swift
DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
    try? FileManager.default.removeItem(atPath: backupPath)
}
```

- 给 FileProvider Extension 5 秒时间检测数据库变化
- 允许正在进行的操作完成
- 避免立即删除导致的完整性错误

## 预期效果

修复后：
- ✅ 不再出现数据库完整性错误
- ✅ 文件列表正常显示
- ✅ 主应用和 FileProvider Extension 可以安全共享数据库
- ✅ 重复初始化时复用现有数据库，提高性能

## 测试验证

### 测试场景 1：首次创建保险库
```
预期：创建新数据库，正常初始化
日志：✅ 数据库初始化完成
```

### 测试场景 2：重复连接同一保险库
```
预期：复用现有数据库，跳过初始化
日志：✅ 数据库已存在且保险库ID匹配，跳过初始化
```

### 测试场景 3：连接不同保险库
```
预期：安全删除旧数据库，创建新数据库
日志：
  ⚠️ 保险库ID不匹配，需要重新初始化
  ✅ 旧数据库已备份到: xxx.backup.xxx
  ✅ 数据库初始化完成
```

### 测试场景 4：FileProvider 正在使用数据库
```
预期：重命名不影响 FileProvider，延迟删除备份
日志：
  ✅ 旧数据库已备份
  （5秒后）🗑️ 已删除数据库备份
```

## 相关文件

- [`CloudDriveCore/VFSDatabase.swift`](CloudDriveCore/VFSDatabase.swift) - 数据库管理（已修复）
- [`CloudDrive/AppState.swift`](CloudDrive/AppState.swift) - 应用状态管理
- [`CloudDriveFileProvider/FileProviderExtension.swift`](CloudDriveFileProvider/FileProviderExtension.swift) - FileProvider 扩展

## 其他改进建议

### 1. 数据库连接池
考虑实现连接池来管理多进程访问：
```swift
class DatabaseConnectionPool {
    private static var connections: [String: OpaquePointer] = [:]
    
    static func getConnection(for vaultId: String) -> OpaquePointer? {
        // 返回现有连接或创建新连接
    }
}
```

### 2. 文件锁机制
使用文件锁确保数据库操作的原子性：
```swift
let lockFile = dbPath.path + ".lock"
// 使用 flock() 或 NSFileLock
```

### 3. 数据库版本管理
添加数据库版本号，支持平滑升级：
```swift
struct DatabaseVersion {
    static let current = 1
    
    func migrate(from oldVersion: Int) throws {
        // 数据库迁移逻辑
    }
}
```

## 总结

这次修复解决了多进程共享数据库时的完整性问题：

1. **避免直接删除**：使用重命名代替删除
2. **智能复用**：检查并复用现有数据库
3. **延迟清理**：给其他进程时间关闭连接
4. **安全备份**：保留备份便于调试

修复后，应用应该能够正常显示文件列表，不再出现数据库完整性错误。