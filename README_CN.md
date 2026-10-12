# CloudDrive

> **Native macOS File Provider for Cryptomator + WebDAV — encrypted files appear directly in Finder and download only when opened. Free and open source.**  
> **面向 Cryptomator + WebDAV 的原生 macOS File Provider — 加密文件直接在访达 (Finder) 中显示，仅在打开时按需流式下载。完全免费且开源。**  
> 🔗 **项目开源地址 (GitHub)**: [https://github.com/dokisekai/CloudDrive](https://github.com/dokisekai/CloudDrive)

[English](README.md) | [简体中文](README_CN.md)

基于 Apple 现代 File Provider 扩展架构（`NSFileProviderReplicatedExtension`）构建，无须内核扩展 (No KEXT) 或第三方 FUSE，让远端 WebDAV 与 Cryptomator 端到端零知识加密库以原生驱动器的方式无缝融入 macOS 访达生态。

---

## ⭐️ 当前可用状态与支持能力

> [!NOTE]
> **当前可用性说明**：
> - **已验证并生产就绪**：**WebDAV** 协议存储接入、**Cryptomator 格式端到端加密保险库**、**原生 Finder 按需下载 (Hydration)**、**事务级双向同步机制**。
> - **仅启用 WebDAV**：S3、SMB/CIFS、FTP、123 云盘及本地文件夹入口和连接均已停用。历史配置保留，但不会自动挂载。

### 核心特性

- 🛡️ **100% 完全兼容 Cryptomator 官方标准**：
  - **双向无缝互通**：完美支持直接打开由 Cryptomator 官方桌面端（macOS/Windows/Linux）或移动端（iOS/Android）创建的既有保险库；在 CloudDrive 中创建的保险库亦可随时被 Cryptomator 官方应用解锁访问，两端完全兼容、任意无缝切换。
  - **严格遵循官方密码学规范**：完整实现 Vault Format 7/8 规范（AES-256-GCM 认证数据加密、Scrypt 强抗暴力破解密钥派生、RFC 4648 Base32 文件名加密与长文件名转义、`d/` 顶层目录两级打散与 `dir.c9r` 真实路径映射）。
  - **纯 Swift 现代架构**：直接基于官方推荐的 `cryptolib-swift` 原生库构建，无须 Java 虚拟机，告别内存泄露与高开销。
- 🌐 **黄金搭档：Alist + Cryptomator + CloudDrive = 全网盘原生加密神器**：
  - **聚合万盘**：搭配 [Alist](https://github.com/alist-org/alist) 可轻松将百度网盘、夸克网盘、阿里云盘、115网盘、OneDrive、Google Drive、PikPak、天翼云等数十种云盘聚合转换为标准 WebDAV。
  - **零知识隐私加固**：在任意网盘上直接架设 Cryptomator 端到端零知识加密保险库，云盘服务商与第三方只能看到被加密打散的密文块，无法窥探任何真实文件名与文件内容。
  - **极速按需加载**：动辄几 TB 的云端加密文件直接在访达中以原生目录呈现，双击即时流式加载，右键随时释放本地存储，告别臃肿且侵入性强的各网盘官方客户端。
- ☁️ **原生按需下载 (Dataless Files)**：初始挂载仅拉取文件目录树元数据，不占用本地磁盘；双击或调用时流式即时物化，支持随时右键“移除下载内容”释放本地空间。解决 Cryptomator 官方在 macOS 上缺乏原生 File Provider 集成（[#1590](https://github.com/cryptomator/cryptomator/issues/1590)）的核心痛点。
- 🔒 **坚固的数据安全与防冲突机制**：
  - **不可变代次**：编辑先落盘至暂存代次，再入 SQLite WAL 事务，杜绝在途竞态；
  - **条件写入**：上传携带 `If-Match` / `If-None-Match`，遇到云端版本竞争（HTTP 412）自动分叉副本，绝不静默覆盖；
  - **软删除墓碑**：本地与远端删除支持安全墓碑机制与持久保护。
- ⚡️ **沉浸式 macOS 原生体验**：纯 Swift & SwiftUI 编写，集成菜单栏快捷状态面板，支持离线编辑与联网自动回写。

---

## 快速上手与编译测试

详细配置说明、截图流程与疑难排查，请参阅 📖 **[完整使用指南 (docs/usage-guide_CN.md)](docs/usage-guide_CN.md)**。

### 系统要求
- **操作系统**：**macOS 15.0 (Sequoia) 或更高版本**（基于现代 File Provider 扩展架构构建）。
- **硬件平台**：**Universal 通用架构**（原生支持 Apple Silicon M1/M2/M3/M4 与 Intel x86_64 Mac）。
- **开发工具**：Xcode 16+（仅源码编译需要，使用预编译包无需安装）。

### 1. 安装与激活

无论您是普通用户还是开发者，均**无需付费的 Apple 开发者账号**：

#### 选项 A：使用预编译版本（免装 Xcode，推荐普通用户）
> 官方 Release 预编译包已采用 **Universal 2 通用二进制**（内置 `arm64` 与 `x86_64` 原生架构，适配所有 Mac）。

1. 从 Releases 下载 `CloudDrive-macOS-Release.zip` 解压并将 `CloudDrive.app` 移动至 `/Applications`；
2. 运行解压包附带的本地激活脚本（清除隔离属性并自动绑定本机沙盒与 Finder 权限）：
   ```bash
   bash activate.sh
   # 或者在克隆仓库中运行：./scripts/activate.sh
   ```

#### 选项 B：从源码一键构建与安装（适合开发者，需 Xcode 16+）
在仓库根目录执行（默认按本机架构编译，也可传入 `--universal` 编译通用版）：
```bash
./scripts/install.sh
# 如需编译 Universal (arm64 + x86_64) 通用二进制：
# ./scripts/install.sh --universal
```

**脚本自动完成的全套签名与部署流程：**
1. **自动解析与打补丁**：拉取 Swift Package 依赖并自动检测应用 `cryptolib-swift` 依赖修补；
2. **多组件编译**：同时构建主程序 `CloudDrive.app` 与核心系统扩展 `CloudDriveFileProvider.appex`；
3. **自适应代码签名（由内而外严格签名）**：
   - 自动检测钥匙串中的 `Apple Development` 个人/开发证书；
   - 若未检测到证书，自动回退到 **Ad-hoc 本地自签名 (`-`)**；
   - 自动将沙盒（App Sandbox）与应用共享组（App Group `group.net.aabg.CloudDrive`）的授权文件分别注入扩展与主程序；
4. **系统级服务注册**：安装至 `/Applications/CloudDrive.app`，使用 `pluginkit` 注册扩展并重启系统的 `fileproviderd` 与 Finder，自动拉起主程序。

> **若使用 Xcode 图形界面编译：**  
> 打开 `CloudDrive.xcodeproj`，在 `CloudDrive` 和 `CloudDriveFileProvider` 的 **Signing & Capabilities** 中选择您的免费 Apple 个人团队（Personal Team），选择 `CloudDrive` Scheme 直接运行即可。

### 2. 运行自动化测试

在仓库根目录下运行全量自动化测试套件：

```bash
./scripts/test.sh
```

测试覆盖了 WebDAV 驱动、加密解密、路径安全边界、WAL 事务提交以及同步状态机边界条件。

### 3. 添加 WebDAV 保险库

1. 打开 `/Applications/CloudDrive.app` 或点击顶部菜单栏图标；
2. 点击 **“新建保险库”** (+号)；
3. 选择 **“新建加密保险库”**（或“打开已有加密库”、“WebDAV 直连挂载”）；
4. 填写 WebDAV 地址（如 Nextcloud / Alist / 群晖 WebDAV 服务）、用户名与密码；
5. 设置保险库名称与加密主密码；
6. 点击 **“创建并解锁”**，虚拟磁盘将立刻出现在 Finder 侧边栏的“位置”中。

### 4. 一键卸载与数据/缓存彻底清理 (Reset & Uninstall)

如需彻底卸载 CloudDrive 或清空所有本地缓存与配置以重置应用，可运行：

```bash
./scripts/uninstall.sh
```

**支持的常用选项：**
- `./scripts/uninstall.sh --dry-run`：安全预览模式，仅列出将要清理的项目而不做实际删除；
- `./scripts/uninstall.sh --keep-app`：**一键重置模式**，保留 `/Applications/CloudDrive.app`，仅清空所有本地缓存、挂载磁盘、数据库、配置文件与钥匙串密码；
- `./scripts/uninstall.sh --dev`：同时清理本地 Xcode DerivedData 编译缓存与 build 产物；
- `./scripts/uninstall.sh -y`：跳过交互确认，自动执行彻底清理。

**清理覆盖范围：**
1. 终止所有运行中的主程序与 FileProvider 扩展进程；
2. 注销 PlugInKit 系统扩展注册与 LaunchServices 关联；
3. 清理 App Group (`group.net.aabg.CloudDrive`) 核心缓存、VFS 数据库、缩略图与回收站快照；
4. 清理沙盒容器 (`~/Library/Containers`)、Application Scripts 与 Application Support；
5. 重置 UserDefaults 偏好设置域与 HTTP/WebKit 存储；
6. 从 macOS Keychain 安全抹除保存的保险库与存储凭据；
7. 重置 TCC 隐私授权并重启 fileproviderd & Finder，彻底消除侧边栏幽灵磁盘。

---

## 项目结构

```text
Sources/
  CloudDrive/              SwiftUI 主程序与菜单栏交互
  CloudDriveCore/          核心业务层与统一门面
  CloudDriveFileProvider/  macOS File Provider 系统扩展 (Finder 挂载核心)
  CloudDriveStorage/       存储驱动 (仅启用 WebDAV，保留历史类型兼容)
  CloudDriveCrypto/        Cryptomator 兼容端到端加密驱动 (AES-GCM + Scrypt)
  CloudDrivePersistence/   SQLite WAL 状态机与元数据持久化
  CloudDriveCache/         两级缓存管理、不可变 Payload 暂存与租约驱逐
  CloudDriveSync/          权威同步引擎、条件写入与冲突分叉调度
  CloudDriveRecovery/      回收站存储与软删除墓碑生命周期管理
  CloudDriveVFS/           虚拟文件系统路由 (直连映射与加密映射)
  CloudDriveContracts/     领域协议接口、数据契约与常量定义
  CloudDriveSupport/       日志系统、沙盒路径布局与全局设置
Tests/
  CloudDriveCoreTests/     核心同步内核与单元测试套件
scripts/
  activate.sh             预编译包本地激活与权限重签名 (免 Xcode)
  install.sh              源码一键依赖处理、构建、签名与安装
  uninstall.sh            一键彻底卸载、清理应用缓存、配置与钥匙串凭据
  package.sh              Release 通用双架构分发包打包脚本
  test.sh                 依赖准备与集成测试运行
  patches/                第三方开源库必要适配补丁
docs/
  usage-guide.md          📖 使用指南 (English)
  usage-guide_CN.md       📖 使用指南 (中文)
  architecture.md         系统架构与模块拓扑
  sync-specification.md   同步内核与状态机规范 (DDL/WAL/冲突分叉)
  data-safety-review.md   数据安全审查与风险登记表
  storage-matrix.md       多协议存储能力与限制矩阵
  modularization-plan.md  分层模块化设计方案
CloudDrive.xcodeproj/      Xcode 工程配置
Package.swift              Swift Package 配置
LICENSE                    MIT 许可证
```

---

## 技术规范文档

- 📖 **[使用指南 (English)](docs/usage-guide.md)** | **[使用指南 (中文)](docs/usage-guide_CN.md)**
- 📐 **[系统架构与模块拓扑](docs/architecture.md)**：File Provider 扩展架构与数据流流转。
- ⚙️ **[同步内核与状态机规范](docs/sync-specification.md)**：代次管理、条件请求与冲突分叉机制。
- 🛡️ **[数据安全审查与风险登记表](docs/data-safety-review.md)**：防丢防损与边界防护分析。
- 📊 **[多协议存储能力与限制矩阵](docs/storage-matrix.md)**：各存储协议（WebDAV / S3 / SMB / FTP）能力与限制对比。

---

## 许可证

本项目遵循 [MIT 许可证](LICENSE)。
