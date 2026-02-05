# CloudDrive 调试指南

本文档介绍 CloudDrive 项目三个主要模块的调试方式和最佳实践。

## 目录

- [项目 Target 结构](#项目-target-结构)
- [客户端调试](#客户端调试)
- [核心库调试](#核心库调试)
- [文件服务调试](#文件服务调试)
- [调试建议](#调试建议)
- [常见调试场景](#常见调试场景)
- [总结](#总结)

---

## 项目 Target 结构

```
CloudDrive/
├── CloudDrive              # 客户端应用（macOS App）
├── CloudDriveCore          # 核心框架库（Framework）
└── CloudDriveFileProvider  # 文件服务扩展（File Provider Extension）
```

| Target | 类型 | 产品类型 | 调试难度 |
|--------|------|----------|----------|
| CloudDrive | 应用 | `com.apple.product-type.application` | ⭐ 简单 |
| CloudDriveCore | 框架 | `com.apple.product-type.framework` | ⭐ 简单 |
| CloudDriveFileProvider | 扩展 | `com.apple.product-type.app-extension` | ⭐⭐⭐ 复杂 |

---

## 客户端调试

### 基本信息

**Target**: `CloudDrive`
**类型**: macOS 应用
**调试难度**: ⭐ 简单

### 调试方式

#### 方式一：直接运行调试（推荐）

```bash
# 在 Xcode 中
1. 选择 CloudDrive scheme
2. 点击 Debug 按钮 (▶️) 或按 Cmd + R
3. 应用启动后可以设置断点、查看变量、使用 LLDB 命令
```

#### 方式二：命令行构建和运行

```bash
# 构建
xcodebuild -scheme CloudDrive -configuration Debug build

# 运行
open ~/Library/Developer/Xcode/DerivedData/CloudDrive-*/Build/Products/Debug/CloudDrive.app
```

### 调试技巧

1. **设置条件断点**
   - 右键断点 → Edit Breakpoint
   - 添加条件表达式（如 `vaultId == "xxx"`）

2. **查看 SwiftUI 状态**
   ```swift
   // 在 @Published 属性上设置断点
   // Xcode 会自动打印当前值
   @Published var isVaultUnlocked = false
   ```

3. **使用 LLDB 命令**
   ```bash
   # 查看变量
   po vault

   # 查看所有属性
   po appState

   # 调用方法
   po appState.vaults.count

   # 查看调用栈
   bt
   ```

### 相关文件

- `CloudDrive/AppState.swift` - 应用状态管理
- `CloudDrive/ContentView.swift` - 主界面
- `CloudDrive/CreateVaultView.swift` - 创建保险库视图

---

## 核心库调试

### 基本信息

**Target**: `CloudDriveCore`
**类型**: macOS 框架
**调试难度**: ⭐ 简单

### 调试方式

#### 方式一：通过客户端调试（最常用）

核心库是客户端的依赖，调试客户端时会自动调试核心库代码。

```swift
// 在核心库中设置断点
// CloudDriveCore/VirtualFileSystem.swift:432
public func mountVaultWithoutEncryption(...) async throws {
    // 在这里设置断点
    print("🔓 VFS: 挂载保险库（无加密模式）")
    // ...
}
```

#### 方式二：单元测试

```bash
# 运行核心库单元测试
xcodebuild test \
  -scheme CloudDriveCore \
  -destination 'platform=macOS' \
  -configuration Debug
```

#### 方式三：创建独立的测试应用

创建一个简单的命令行工具或 macOS 应用来测试核心库功能。

```swift
// 示例：测试 WebDAV 连接
import CloudDriveCore

let vfs = VirtualFileSystem.shared
vfs.configureWebDAV(
    baseURL: URL(string: "https://webdav.example.com")!,
    username: "test",
    password: "test"
)

// 设置断点并测试
let files = try vfs.listDirectory(directoryId: "ROOT")
print(files)
```

### 调试技巧

1. **使用 print 语句快速调试**
   ```swift
   print("🔍 VFS: 当前状态 - vaultId: \(currentVaultId ?? "nil")")
   ```

2. **查看加密解密过程**
   ```swift
   // CloudDriveCore/VFSEncryption.swift
   // 在加密方法中设置断点
   public func encrypt(data: Data, key: SymmetricKey) throws -> Data {
       // 断点：查看加密前的数据
       // 断点：查看加密后的数据
       // ...
   }
   ```

3. **数据库调试**
   ```swift
   // CloudDriveCore/VFSDatabase.swift
   // 查看 SQL 查询
   func listChildren(parentId: String) throws -> [VirtualFileItem] {
       // 在这里设置断点查看 SQL
       // ...
   }
   ```

### 相关文件

- `CloudDriveCore/VirtualFileSystem.swift` - 虚拟文件系统
- `CloudDriveCore/WebDAVClient.swift` - WebDAV 客户端
- `CloudDriveCore/VFSDatabase.swift` - 本地数据库
- `CloudDriveCore/VFSEncryption.swift` - 加密解密

---

## 文件服务调试

### 基本信息

**Target**: `CloudDriveFileProvider`
**类型**: File Provider Extension
**调试难度**: ⭐⭐⭐ 复杂

**说明**：File Provider Extension 是一个特殊类型的进程，由系统按需启动，不能直接运行。

### 调试方式

#### 方式一：Attach 到运行中的进程

```bash
# 1. 运行主应用
xcodebuild -scheme CloudDrive build
open ~/Library/Developer/Xcode/DerivedData/CloudDrive-*/Build/Products/Debug/CloudDrive.app

# 2. 查找扩展进程
ps aux | grep -i fileprovider

# 输出示例：
# user  1234  ... CloudDriveFileProvider

# 3. 使用 lldb attach
lldb -p 1234

# 4. 设置断点
(lldb) breakpoint set --file FileProviderExtension.swift --line 50
(lldb) continue
```

#### 方式二：通过 Xcode Scheme 配置（推荐）

1. **配置 Scheme**
   ```
   1. 选择 CloudDriveFileProvider scheme
   2. Product → Scheme → Edit Scheme...
   3. 选择 "Run"
   4. "Info" 标签页
   5. Executable 选择 "Ask on Launch"
   ```

2. **运行和调试**
   ```
   1. 先运行 CloudDrive 应用
   2. 在 Finder 中打开虚拟盘（触发扩展启动）
   3. Xcode 会提示 "Would you like to attach to process?"
   4. 点击 "Attach"
   ```

#### 方式三：日志调试（最可靠）

由于扩展难以直接调试，日志是最可靠的方式。

**在代码中添加日志**：
```swift
import os

// CloudDriveFileProvider/FileProviderExtension.swift
let logger = Logger(subsystem: "net.aabg.CloudDrive", category: "FileProvider")

class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    required init(domain: NSFileProviderDomain) {
        logger.debug("FileProvider Extension 正在初始化")
        logger.debug("域名: \(domain.identifier.rawValue)")
        super.init()
        // ...
    }
}
```

**查看实时日志**：
```bash
# 查看所有 CloudDrive 日志
log stream --predicate 'subsystem == "net.aabg.CloudDrive"' \
  --level debug \
  --style compact

# 只查看 FileProvider 日志
log stream --predicate 'subsystem == "net.aabg.CloudDrive" AND category == "FileProvider"' \
  --level debug

# 查看过去一小时的日志
log show --last 1h --predicate 'subsystem == "net.aabg.CloudDrive"' \
  --level debug
```

#### 方式四：使用 Console.app

```bash
# 打开控制台应用
open /Applications/Utilities/Console.app
```

在 Console.app 中：
1. 在搜索框输入 `CloudDrive`
2. 过滤级别：Debug, Info, Error
3. 查看实时日志流

#### 方式五：调试扩展生命周期

在关键的生命周期方法中添加日志：

```swift
class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier) throws -> NSFileProviderEnumerator {
        logger.debug("🔍 创建枚举器: \(containerItemIdentifier.rawValue)")
        // ...
    }

    func item(for identifier: NSFileProviderItemIdentifier) throws -> NSFileProviderItem {
        logger.debug("📄 获取项目: \(identifier.rawValue)")
        // ...
    }

    func url(for itemIdentifier: NSFileProviderItemIdentifier) throws -> URL {
        logger.debug("🔗 获取 URL: \(itemIdentifier.rawValue)")
        // ...
    }
}
```

### 常见问题和解决方案

#### 问题 1：扩展无法启动

**症状**：打开虚拟盘时没有任何响应

**调试步骤**：
```bash
# 1. 检查扩展是否已安装
ls -la ~/Library/Containers/com.apple.FileProvider/*/Data/Library/Application\ Support/

# 2. 检查权限
codesign -dvv ~/Library/Developer/Xcode/DerivedData/CloudDrive-*/Build/Products/Debug/CloudDrive.app/Contents/PlugIns/CloudDriveFileProvider.appex

# 3. 查看系统日志
log show --predicate 'subsystem == "com.apple.FileProvider"' \
  --last 10m \
  --level debug
```

#### 问题 2：文件列表不显示

**症状**：在 Finder 中看不到文件

**调试步骤**：
```swift
// 在 enumerator 方法中添加日志
func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
    logger.debug("📋 开始枚举项目，page: \(page)")

    do {
        let items = try vfs.listDirectory(directoryId: "ROOT")
        logger.debug("✅ 获取到 \(items.count) 个项目")

        for item in items {
            observer.didEnumerate(item)
            logger.debug("   - \(item.name)")
        }
    } catch {
        logger.error("❌ 枚举失败: \(error)")
    }
}
```

#### 问题 3：文件下载失败

**症状**：点击文件无法打开

**调试步骤**：
```swift
// 在 url(for:) 方法中添加日志
func url(for itemIdentifier: NSFileProviderItemIdentifier) throws -> URL {
    logger.debug("⬇️ 开始下载文件: \(itemIdentifier.rawValue)")

    do {
        let cacheURL = try cacheManager.cacheFile(fileId: itemIdentifier.rawValue)
        logger.debug("✅ 文件已缓存: \(cacheURL.path)")
        return cacheURL
    } catch {
        logger.error("❌ 文件下载失败: \(error)")
        throw error
    }
}
```

### 相关文件

- `CloudDriveFileProvider/FileProviderExtension.swift` - 扩展主入口
- `CloudDriveFileProvider/FileProviderItem.swift` - 文件项目定义
- `CloudDriveFileProvider/Info.plist` - 扩展配置

---

## 调试建议

### 开发流程

1. **优先调试客户端和核心库**
   - 这两个部分可以完全控制
   - 调试最方便
   - 先确保核心功能正常

2. **使用日志调试文件服务**
   - File Provider Extension 的状态难以直接观察
   - 日志是最可靠的方式
   - 实时查看日志流

3. **分步验证**
   - 先确保核心库功能正常（WebDAV 连接、加密解密、数据库）
   - 再调试应用层（UI、状态管理）
   - 最后调试文件服务集成

### 日志配置

项目在关键位置都配置了日志：

| 模块 | 日志位置 | 用途 |
|------|----------|------|
| AppState | 应用状态管理 | 挂载卸载状态、保险库管理 |
| VirtualFileSystem | 文件系统操作 | 文件列表、上传下载、加密解密 |
| FileProviderExtension | 文件服务扩展 | Finder 集成、文件枚举 |

### 快速调试命令

```bash
# 查看所有 CloudDrive 日志（实时）
log stream --predicate 'subsystem == "net.aabg.CloudDrive"' --level debug

# 查看过去 5 分钟的日志
log show --last 5m --predicate 'subsystem == "net.aabg.CloudDrive"' --level debug

# 只查看错误日志
log stream --predicate 'subsystem == "net.aabg.CloudDrive" AND level == error'

# 导出日志到文件
log show --predicate 'subsystem == "net.aabg.CloudDrive"' \
  --last 1h \
  > clouddrive_debug.log
```

### Xcode 调试快捷键

| 快捷键 | 功能 |
|--------|------|
| `Cmd + R` | 运行 |
| `Cmd + .` | 停止 |
| `Cmd + Shift + K` | 清理构建 |
| `Cmd + B` | 构建 |
| `Cmd + Y` | 激活/禁用断点 |
| `Cmd + \` | 在当前行设置/取消断点 |
| `Ctrl + Cmd + Y` | 继续执行 |
| `Ctrl + Cmd + Shift + Space` | 显示控制台 |

---

## 常见调试场景

### 场景 1：挂载卸载问题

**症状**：无法挂载或卸载保险库

**调试步骤**：

```bash
# 1. 监控应用状态日志
log stream --predicate 'subsystem == "net.aabg.CloudDrive" AND category == "AppState"' \
  --level debug

# 2. 查看 AppState.swift 中的状态变化
# 断点位置：
# - AppState.remountVault():474
# - AppState.unmountVault():541
# - VirtualFileSystem.remountDirectMappingVault():433
```

**关键日志输出**：
```
📂 AppState: 重新挂载保险库: WebDAV 存储
✅ AppState: 从 Keychain 获取到密码
⚙️ VFS: 配置 WebDAV 存储
🔓 VFS: 重新挂载直接映射保险库
✅ VFS: 已经挂载了同一个保险库，跳过
✅ AppState: 保险库重新挂载成功
```

### 场景 2：WebDAV 连接问题

**症状**：无法连接到 WebDAV 服务器

**调试步骤**：

```bash
# 1. 查看 WebDAV 相关日志
log stream --predicate 'subsystem == "net.aabg.CloudDrive" AND category == "WebDAV"' \
  --level debug

# 2. 检查网络连接
curl -I -u "username:password" https://webdav.example.com

# 3. 使用 Wireshark 或 tcpdump 抓包分析
sudo tcpdump -i any -nn host webdav.example.com
```

**关键日志输出**：
```
⚙️ VFS: 配置 WebDAV 存储
   URL: https://webdav.example.com
✅ VFS: WebDAV 存储配置完成
🔍 AppState: 测试 WebDAV 连接...
✅ AppState: WebDAV 连接测试成功
```

### 场景 3：文件列表不显示

**症状**：在应用或 Finder 中看不到文件列表

**调试步骤**：

```bash
# 1. 查看 VFS 和 FileProvider 日志
log stream --predicate 'subsystem == "net.aabg.CloudDrive" AND (category == "VFS" OR category == "FileProvider")' \
  --level debug

# 2. 断点位置：
# - VirtualFileSystem.listDirectory():589
# - VirtualFileSystem.listDirectoryFromWebDAV():618
# - FileProviderExtension.enumerator():xxx
```

**关键日志输出**：
```
📂 VFS.listDirectoryFromWebDAV: 开始
   目录ID: ROOT
📂 VFS: WebDAV 路径: /
✅ VFS: 获取到 5 个项目
   - 📁 Documents
   - 📁 Pictures
   - 📄 test.txt
```

### 场景 4：文件上传下载失败

**症状**：无法上传或下载文件

**调试步骤**：

```bash
# 1. 查看文件操作日志
log stream --predicate 'subsystem == "net.aabg.CloudDrive" AND (message contains "upload" OR message contains "download")' \
  --level debug

# 2. 断点位置：
# - VirtualFileSystem.uploadFile():870
# - VirtualFileSystem.downloadFile():981
# - FileProviderSync.startDownload():xxx
```

**关键日志输出**：
```
⬆️ VFS.uploadFile: 开始上传文件
   文件名: test.txt
   父目录ID: /Documents
📊 VFS: 文件大小: 1024 字节
📡 VFS: 直接下载
   WebDAV 路径: /Documents/test.txt
📊 VFS: 上传进度: 20%
📊 VFS: 上传进度: 40%
📊 VFS: 上传进度: 60%
📊 VFS: 上传进度: 80%
📊 VFS: 上传进度: 100%
✅ VFS: 文件上传成功
```

### 场景 5：加密解密问题

**症状**：加密的文件无法解密或数据损坏

**调试步骤**：

```bash
# 1. 查看加密相关日志
log stream --predicate 'subsystem == "net.aabg.CloudDrive" AND message contains "encrypt" OR message contains "decrypt"' \
  --level debug

# 2. 断点位置：
# - VFSEncryption.generateMasterKey():xxx
# - VFSEncryption.encrypt():xxx
# - VFSEncryption.decrypt():xxx
```

**关键日志输出**：
```
🔑 VFS: 生成主密钥和盐...
✅ VFS: 主密钥生成成功
🧂 VFS: 盐生成成功 (长度: 16 字节)
🔐 VFS: 配置已加密，大小: 256 字节
🔓 VFS: 解密配置...
✅ VFS: 配置解密成功
```

---

## 总结

| 模块 | 调试难度 | 推荐方式 | 工具 |
|------|----------|----------|------|
| **客户端** | ⭐ 简单 | 直接运行调试 | Xcode, LLDB |
| **核心库** | ⭐ 简单 | 通过客户端或单元测试 | Xcode, XCTest |
| **文件服务** | ⭐⭐⭐ 复杂 | 日志调试 | Console.app, log 命令 |

### 最佳实践

1. **日志驱动开发**
   - 在关键位置添加详细的日志
   - 使用结构化日志（os.log）
   - 定期查看和分析日志

2. **断点辅助调试**
   - 在核心算法和关键流程设置断点
   - 使用条件断点减少干扰
   - 配合 print 语句快速定位

3. **分模块测试**
   - 先测试核心库（WebDAV、加密、数据库）
   - 再测试应用层（UI、状态管理）
   - 最后测试集成（文件服务）

4. **使用工具链**
   - Xcode：应用和核心库调试
   - Console.app：系统日志查看
   - Wireshark/tcpdump：网络抓包
   - sqlite3：数据库查询

### 相关文档

- [README.md](../README.md) - 项目介绍
- [README-cn.md](../README-cn.md) - 中文项目介绍
- docs/ 目录下的其他技术文档

### 获取帮助

如果遇到问题：
1. 查看本文档的相关章节
2. 检查日志输出
3. 使用断点调试
4. 参考示例代码

---

**文档版本**: 1.0
**最后更新**: 2026年2月
**维护者**: CloudDrive Team
