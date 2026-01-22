# CloudDrive - WebDAV 云盘挂载系统

一个专为 Apple 设备设计的 WebDAV 云盘挂载解决方案，可将 WebDAV 服务器直接挂载到 macOS 侧边栏，实现类似 iCloud 的无缝文件访问体验。

## 📋 项目简介

CloudDrive 是一个原生的 macOS 应用程序，利用 Apple 的 File Provider 框架，将远程 WebDAV 服务器挂载为本地文件系统。用户可以像访问本地文件一样访问云端文件，系统会自动处理文件的下载、缓存和同步。

### 🎯 设计目标

- **macOS 原生集成**：挂载到 Finder 侧边栏，与系统深度集成
- **透明文件访问**：直接映射 WebDAV 路径，无需复杂的加密层
- **智能缓存管理**：自动缓存常用文件，节省带宽和存储空间
- **后期支持 iOS**：架构设计考虑了未来的 iOS 扩展

### ⚠️ 当前状态

**开发中** - 核心功能已实现，但仍在完善中：

✅ **已实现功能**：
- WebDAV 服务器连接和认证
- 文件/目录的浏览、创建、上传、下载、删除
- 本地文件缓存（LRU 策略，最大 10GB）
- macOS Finder 侧边栏挂载
- 直接路径映射（WebDAV 路径 ↔ 本地路径）
- 基础的同步状态管理

🚧 **待完善功能**：
- 云端到本地的自动同步逻辑
- 文件变更监听和增量同步
- 冲突解决机制
- 离线模式优化
- iOS 客户端支持

## 🏗️ 系统架构

```
┌─────────────────────────────────────────────────────────┐
│                    macOS Finder                         │
│              (用户通过侧边栏访问文件)                      │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│           File Provider Extension                       │
│  • 处理 Finder 的文件操作请求                             │
│  • 管理文件枚举和元数据                                   │
│  • 协调缓存和下载                                         │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│              Virtual File System (VFS)                  │
│  • 直接映射 WebDAV 路径                                   │
│  • 管理文件元数据                                         │
│  • 协调存储客户端                                         │
└────────────────────┬────────────────────────────────────┘
                     │
        ┌────────────┴────────────┐
        ▼                         ▼
┌──────────────────┐    ┌──────────────────┐
│  Cache Manager   │    │  WebDAV Client   │
│  • LRU 缓存策略  │    │  • HTTP 请求     │
│  • 本地文件存储  │    │  • 认证管理      │
│  • 缓存清理      │    │  • 文件传输      │
└──────────────────┘    └────────┬─────────┘
                                 │
                                 ▼
                        ┌──────────────────┐
                        │  WebDAV Server   │
                        │  (远程存储)       │
                        └──────────────────┘
```

## 📦 项目结构

```
CloudDrive/
├── CloudDrive/                      # 主应用程序
│   ├── CloudDriveApp.swift         # 应用入口
│   ├── ContentView.swift           # 主界面
│   ├── CreateVaultView.swift       # 创建保险库界面
│   ├── SettingsView.swift          # 设置界面
│   └── AppState.swift              # 应用状态管理
│
├── CloudDriveCore/                  # 核心框架（共享代码）
│   ├── VirtualFileSystem.swift     # 虚拟文件系统核心
│   ├── WebDAVClient.swift          # WebDAV 客户端
│   ├── StorageClient.swift         # 存储抽象层
│   ├── CacheManager.swift          # 缓存管理器
│   ├── SyncManager.swift           # 同步管理器
│   ├── VFSDatabase.swift           # 本地数据库
│   ├── Logger.swift                # 日志系统
│   └── KeychainService.swift       # 密钥链服务
│
├── CloudDriveFileProvider/          # File Provider 扩展
│   ├── FileProviderExtension.swift # 扩展主类
│   ├── FileProviderItem.swift      # 文件项模型
│   └── Info.plist                  # 扩展配置
│
└── CloudDrive.xcodeproj/            # Xcode 项目文件
```

## 🚀 快速开始

### 系统要求

- **macOS**: 14.0 (Sonoma) 或更高版本
- **Xcode**: 15.0 或更高版本
- **Swift**: 5.9 或更高版本
- **WebDAV 服务器**: 任何支持标准 WebDAV 协议的服务器

### 安装步骤

#### 1. 克隆项目

```bash
git clone <repository-url>
cd CloudDrive
```

#### 2. 配置项目

```bash
# 配置 App Group 和代码签名
./configure_project.sh
```

#### 3. 编译项目

在 Xcode 中打开 `CloudDrive.xcodeproj`：

```bash
open CloudDrive.xcodeproj
```

或使用命令行编译：

```bash
xcodebuild clean build -project CloudDrive.xcodeproj -scheme CloudDrive
```

#### 4. 运行应用

1. 在 Xcode 中选择 `CloudDrive` scheme
2. 点击运行按钮（Cmd+R）
3. 应用将启动并显示主界面

### 配置 WebDAV 服务器

#### 使用现有 WebDAV 服务器

如果你已有 WebDAV 服务器（如 Nextcloud、ownCloud、Synology NAS 等），直接使用其 WebDAV 地址即可。

#### 本地测试服务器（可选）

项目包含一个简单的 Node.js WebDAV 测试服务器：

```bash
cd WebServer
npm install
npm start
```

默认配置：
- 地址：`http://localhost:3000`
- 用户名：`admin`
- 密码：`password`

### 创建并挂载保险库

1. **启动应用**：运行 CloudDrive 应用

2. **创建保险库**：
   - 点击"创建新保险库"按钮
   - 输入保险库名称（如 "我的云盘"）
   - 输入 WebDAV 服务器信息：
     - 服务器地址：`http://your-server:port/webdav`
     - 用户名：你的 WebDAV 用户名
     - 密码：你的 WebDAV 密码
   - 点击"创建"

3. **挂载到 Finder**：
   - 创建成功后，保险库会自动挂载
   - 打开 Finder，在侧边栏中找到 "CloudDrive"
   - 现在可以像访问本地文件夹一样访问云端文件了！

## 💡 使用说明

### 基本操作

#### 浏览文件
- 在 Finder 侧边栏点击 "CloudDrive"
- 像浏览本地文件夹一样浏览云端文件
- 文件夹和文件会实时从 WebDAV 服务器加载

#### 上传文件
- 直接拖拽文件到 CloudDrive 文件夹
- 或使用复制粘贴（Cmd+C / Cmd+V）
- 文件会自动上传到 WebDAV 服务器

#### 下载文件
- 双击文件即可打开（自动下载）
- 文件会缓存到本地，下次访问更快
- 缓存文件存储在：`~/Library/Caches/com.clouddrive.app/`

#### 创建文件夹
- 在 CloudDrive 中右键 → "新建文件夹"
- 文件夹会立即在 WebDAV 服务器上创建

#### 删除文件
- 选中文件 → 右键 → "移到废纸篓"
- 或按 Cmd+Delete
- 文件会从 WebDAV 服务器删除

### 缓存管理

#### 缓存策略
- **自动缓存**：打开的文件自动缓存
- **LRU 淘汰**：缓存满时自动删除最久未使用的文件
- **最大容量**：默认 10GB（可在设置中调整）

#### 查看缓存状态
```bash
# 查看缓存目录
open ~/Library/Caches/com.clouddrive.app/

# 查看缓存大小
du -sh ~/Library/Caches/com.clouddrive.app/
```

#### 清理缓存
```bash
# 清理所有缓存
rm -rf ~/Library/Caches/com.clouddrive.app/
```

### 同步状态

文件同步状态图标：
- ☁️ **仅云端**：文件未下载到本地
- ✅ **已同步**：文件已下载并与云端同步
- 🔄 **同步中**：正在上传或下载
- ⚠️ **待同步**：等待网络恢复后同步

## 🔧 技术细节

### File Provider 框架

CloudDrive 使用 Apple 的 File Provider 框架实现系统级集成：

- **NSFileProviderReplicatedExtension**：处理文件操作请求
- **NSFileProviderEnumerator**：枚举目录内容
- **NSFileProviderItem**：表示文件和文件夹

### 直接路径映射

为了简化实现，CloudDrive 采用直接路径映射策略：

```
WebDAV 路径          →  本地标识符
/folder/file.txt    →  /folder/file.txt
/documents/         →  /documents/
```

这种设计的优点：
- 实现简单，易于理解和维护
- 路径透明，便于调试
- 无需复杂的 ID 映射表

### 缓存机制

```swift
// LRU 缓存策略
class CacheManager {
    // 最大缓存大小：10GB
    private let maxCacheSize: Int64 = 10 * 1024 * 1024 * 1024
    
    // 缓存策略
    enum CachePolicy {
        case automatic  // 自动管理
        case pinned     // 固定（不会被清理）
        case temporary  // 临时（优先清理）
    }
}
```

### WebDAV 客户端

支持标准 WebDAV 操作：

- **PROPFIND**：列出目录内容
- **GET**：下载文件
- **PUT**：上传文件
- **MKCOL**：创建目录
- **DELETE**：删除文件/目录
- **MOVE**：移动/重命名

### 数据存储

#### 本地数据库
```
~/Library/Application Support/CloudDrive/
└── vaults/
    └── [vault-id]/
        └── vault.db  # SQLite 数据库
```

存储内容：
- 文件和目录的元数据
- 同步状态
- 缓存索引

#### 缓存文件
```
~/Library/Caches/com.clouddrive.app/
└── cache/
    └── [file-id]  # 实际的文件内容
```

## 🐛 故障排除

### File Provider 未显示

如果 Finder 侧边栏中没有显示 CloudDrive：

```bash
# 1. 检查 File Provider 状态
pluginkit -m -p com.apple.FileProvider-nonUI

# 2. 启用扩展
pluginkit -e use -i net.aabg.CloudDrive.FileProvider

# 3. 重启 Finder
killall Finder
```

### 连接 WebDAV 失败

检查清单：
1. ✅ WebDAV 服务器地址是否正确
2. ✅ 用户名和密码是否正确
3. ✅ 服务器是否可访问（ping 测试）
4. ✅ 防火墙是否允许连接
5. ✅ WebDAV 服务是否启用

测试连接：
```bash
# 使用 curl 测试
curl -u username:password -X PROPFIND http://your-server/webdav/
```

### 文件上传失败

可能原因：
- 网络连接中断
- 服务器空间不足
- 权限不足
- 文件名包含非法字符

查看日志：
```bash
# 查看系统日志
log stream --predicate 'subsystem == "net.aabg.CloudDrive"' --level debug

# 查看应用日志
open ~/.CloudDrive/Logs/
```

### 缓存问题

如果遇到缓存相关问题：

```bash
# 清理缓存
rm -rf ~/Library/Caches/com.clouddrive.app/

# 重置数据库
rm -rf ~/Library/Application\ Support/CloudDrive/

# 重启应用
```

## 📊 性能优化

### 缓存优化建议

1. **调整缓存大小**：根据可用磁盘空间调整
2. **固定常用文件**：将常用文件标记为 `pinned`
3. **定期清理**：手动清理不需要的缓存

### 网络优化

1. **使用有线连接**：比 Wi-Fi 更稳定
2. **选择就近服务器**：减少延迟
3. **避免高峰期**：选择网络空闲时段同步大文件

## 🔐 安全性

### 数据传输

- **HTTPS 支持**：建议使用 HTTPS 连接 WebDAV 服务器
- **基本认证**：使用 HTTP Basic Authentication
- **密码存储**：密码安全存储在 macOS Keychain

### 本地数据

- **缓存加密**：缓存文件以明文存储（未来版本将支持加密）
- **权限控制**：使用 macOS 文件系统权限保护
- **沙盒隔离**：应用运行在沙盒环境中

### 安全建议

1. ✅ 使用 HTTPS 而非 HTTP
2. ✅ 使用强密码
3. ✅ 定期更换密码
4. ✅ 不要在公共网络上使用
5. ✅ 启用服务器端加密（如果支持）

## 🛣️ 开发路线图

### 近期计划（v1.0）

- [ ] 完善云端到本地的自动同步
- [ ] 实现文件变更监听
- [ ] 添加冲突解决机制
- [ ] 优化缓存策略
- [ ] 改进错误处理和用户提示

### 中期计划（v1.5）

- [ ] 支持文件加密（端到端加密）
- [ ] 多保险库管理
- [ ] 选择性同步（类似 iCloud）
- [ ] 离线模式增强
- [ ] 性能监控和统计

### 长期计划（v2.0）

- [ ] iOS 客户端支持
- [ ] iPadOS 优化
- [ ] 文件共享功能
- [ ] 版本历史
- [ ] 协作功能

## 📝 开发指南

### 编译要求

- macOS 14.0+
- Xcode 15.0+
- Swift 5.9+
- CocoaPods 或 Swift Package Manager

### 项目配置

```bash
# 1. 配置 App Group
# 在 Xcode 中设置 App Group: group.net.aabg.CloudDrive

# 2. 配置代码签名
# 使用你的 Apple Developer 账号

# 3. 配置 File Provider Extension
# 确保 Extension 的 Bundle ID 正确
```

### 调试技巧

#### 查看日志
```bash
# 实时查看日志
log stream --predicate 'subsystem == "net.aabg.CloudDrive"' --level debug

# 查看 File Provider 日志
log show --predicate 'subsystem == "com.apple.FileProvider"' --last 1h
```

#### 调试 File Provider
```bash
# 附加调试器到 File Provider Extension
lldb -p $(pgrep -f CloudDriveFileProvider)
```

### 贡献指南

欢迎贡献代码！请遵循以下步骤：

1. Fork 项目
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 开启 Pull Request

### 代码规范

- 使用 Swift 官方代码风格
- 添加必要的注释
- 编写单元测试
- 更新文档

## 📄 许可证

本项目采用 MIT 许可证 - 详见 [LICENSE](LICENSE) 文件

## 🙏 致谢

- Apple File Provider 框架文档
- WebDAV 协议规范
- 开源社区的支持

## 📧 联系方式

- **问题反馈**：请在 GitHub Issues 中提交
- **功能建议**：欢迎在 Issues 中讨论
- **安全问题**：请通过私密方式联系

## ⚠️ 免责声明

本项目目前处于开发阶段，仅供学习和测试使用。在生产环境使用前，请：

1. 进行充分的测试
2. 备份重要数据
3. 评估安全风险
4. 考虑使用成熟的商业解决方案

---

**注意**：这是一个教育和演示项目，展示如何使用 Apple File Provider 框架构建云存储挂载系统。虽然核心功能已实现，但仍需要进一步完善才能用于生产环境。

**最后更新**：2026-01-12