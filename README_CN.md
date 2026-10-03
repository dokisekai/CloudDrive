# CloudDrive

[English](README.md) | [简体中文](README_CN.md)

原生 macOS 云存储客户端，基于 Apple File Provider 现代框架构建，无须内核扩展 (No KEXT) 或第三方 FUSE，将远端云存储以原生驱动器的方式无缝挂载至访达 (Finder)。

---

## ⭐️ 当前可用状态与支持能力

> [!NOTE]
> **当前可用性说明**：
> - **已验证并生产就绪**：**WebDAV** 协议存储接入、**Cryptomator 格式端到端加密保险库**、**原生 Finder 按需下载 (Hydration)**、**事务级双向同步机制**。
> - **模块化演进中**：Amazon S3、SMB/CIFS、FTP 协议目前处于驱动骨架与分层演进阶段，当前推荐并唯一通过完整测试的协议为 **WebDAV**。

### 核心特性

- 🛡️ **端到端零知识加密**：采用行业标准的 Cryptomator 格式（AES-256-GCM 数据加密、Scrypt 强抗暴力破解密钥派生、文件名加密与目录打散），可与 Cryptomator 官方客户端跨平台互通。
- ☁️ **原生按需下载 (Dataless Files)**：初始挂载仅拉取文件目录树元数据，不占用本地磁盘；双击或调用时流式即时物化，支持随时右键“移除下载内容”释放本地空间。
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
- **硬件平台**：Apple Silicon (M1/M2/M3/M4) 或 Intel (x86_64) Mac。
- **开发工具**：Xcode 16+（包含 Command Line Tools）。

### 1. 一键构建与安装（自动代码签名）

**无需付费的 Apple 开发者账号！任何人克隆仓库即可直接在本地编译使用。**

在仓库根目录执行：

```bash
./scripts/install.sh
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

---

## 项目结构

```text
Sources/
  CloudDrive/              SwiftUI 主程序与菜单栏交互
  CloudDriveCore/          核心业务层与统一门面
  CloudDriveFileProvider/  macOS File Provider 系统扩展 (Finder 挂载核心)
  CloudDriveStorage/       多协议存储驱动 (WebDAV 生产就绪 / S3, SMB, FTP)
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
  install.sh              一键依赖处理、构建、签名与安装
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
