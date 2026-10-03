# CloudDrive 使用与操作指南 (Usage Guide)

[English](usage-guide.md) | [简体中文](usage-guide_CN.md)

本文档介绍 **CloudDrive** 的核心功能、支持状态、配置步骤以及日常使用方法。

---

## 1. 当前版本支持状态

> [!IMPORTANT]
> **当前可用性说明**：
> - **已验证并生产可用**：**WebDAV** 协议存储接入、**Cryptomator 格式端到端加密保险库**、**原生 File Provider 按需下载与无缝挂载**、**SQLite WAL 事务级双向同步内核**。
> - **实验性 / 开发中**：Amazon S3、SMB/CIFS、FTP 协议目前处于接口定义与模块化演进阶段，当前推荐并唯一通过完整测试的协议为 **WebDAV**。

### 核心支持能力矩阵

| 模块 / 能力 | 支持状态 | 说明 |
| :--- | :---: | :--- |
| **WebDAV 存储源** | ✅ 生产就绪 | 严格遵循 RFC 4918 规范，支持 Nextcloud、Alist、Synology、Nginx 等主流 WebDAV 服务。 |
| **Cryptomator 加密** | ✅ 生产就绪 | 遵循 Cryptomator 格式规范（AES-256-GCM、Scrypt 密钥派生、文件名加密与目录打散），可与官方客户端跨平台互通。 |
| **按需下载 (Hydration)** | ✅ 生产就绪 | 利用 macOS File Provider 原生 Dataless Files，初次仅拉取目录树元数据，按需流式下载，节省本地磁盘。 |
| **不可变代次与防冲突** | ✅ 生产就绪 | 每次编辑生成不可变代次，写入携带 ETag 条件头（`If-Match` / `If-None-Match`），出现版本竞争自动分叉保留副本。 |
| **缓存管理与空间释放** | ✅ 生产就绪 | 支持右键“移除下载内容”释放本地磁盘占用；具备 LRU 缓存租约防误删机制。 |
| **S3 / SMB / FTP** | ⏳ 演进中 | 代码库已包含协议驱动骨架，后续版本逐步开放端到端验证。 |

---

## 2. 准备工作与系统要求

- **操作系统**：**macOS 15.0 (Sequoia) 或更高版本**。
- **硬件平台**：Apple Silicon (M1/M2/M3/M4) 及 Intel (x86_64) Mac。
- **开发工具**：Xcode 16+（包含 Command Line Tools）。
- **代码签名**：**无需付费 Apple 开发者账号**。构建脚本会自动适配个人证书或回退到 Ad-hoc 自签名 (`-`) 并正确绑定 App Group 沙盒权限。
- **权限要求**：构建与安装需要管理员权限（向 `/Applications` 写入并注册系统级 `FileProvider` 扩展）。

---

## 3. 安装与首次配置

### 3.1 一键构建与安装

在仓库根目录下运行自动化构建与注册脚本：

```bash
./scripts/install.sh
```

脚本将自动执行以下操作：
1. 校验 Xcode 开发工具链与 SPM 依赖；
2. 自动修补相关第三方加密库的已知边界问题；
3. 构建主程序 `CloudDrive.app` 与核心扩展 `CloudDriveFileProvider.appex`；
4. 完成本地代码签名与权限沙盒（App Sandbox + App Group）绑定；
5. 安装至 `/Applications/CloudDrive.app` 并注册到系统的 `fileproviderd` 服务。

---

## 4. 详细使用指南

### 4.1 场景一：创建全新加密保险库（推荐）

适用于希望在 WebDAV 云端存储私密敏感文件，且云盘服务商无法解密内容的场景。

1. **启动应用**：从应用程序或状态栏图标打开 CloudDrive 主界面。
2. **添加保险库**：点击主界面的 **“+”** 或 **“新建保险库”** 按钮。
3. **选择模式**：选择 **“新建加密保险库”**（默认选中）。
4. **填写 WebDAV 凭据**：
   - **服务地址**：输入 WebDAV 端点（例如 `https://dav.example.com/remote.php/webdav/` 或 `http://192.168.1.100:5244/dav/`）。
   - **用户名与密码**：输入该 WebDAV 服务的登录凭证。
   - **远程目录**：指定存放加密数据的远端根路径（如 `/MyVault`）。
5. **设置保险库名称与密码**：
   - **保险库名称**：在 Finder 侧边栏显示的驱动器名称（如 `SecureDrive`）。
   - **加密主密码**：用于派生 AES-256 根密钥的主密码。**请务必牢记密码，丢失将无法恢复数据！**
6. **完成挂载**：点击 **“创建并解锁”**。系统将自动初始化远端 Cryptomator 目录结构，并在访达（Finder）侧边栏立即呈现虚拟盘。

---

### 4.2 场景二：打开已有 Cryptomator 保险库

如果之前已在其他设备或使用 Cryptomator 官方客户端创建过保险库，可直接无缝接入：

1. 点击 **“添加保险库”**，模式选择 **“打开已有加密库”**。
2. 输入 WebDAV 连接信息，并在远程目录选择包含 `vault.cryptomator` 的现有文件夹。
3. 输入该加密库的原始主密码。
4. 点击 **“解锁挂载”**，CloudDrive 将自动完成密钥解锁并在 Finder 中挂载。

---

### 4.3 场景三：直连免加密挂载（透明 WebDAV）

适用于只需要将远程 WebDAV 挂载为本地磁盘，不需要进行客户端加密的场景：

1. 点击 **“添加保险库”**，模式选择 **“WebDAV 直连挂载”**。
2. 输入 WebDAV 服务器地址与账号密码，指定目标根目录。
3. 点击 **“挂载”** 即可直接在 Finder 中浏览与同步远端原生文件。

---

## 5. Finder 日常交互与同步机制

CloudDrive 深度集成 macOS 原生 File Provider，体验与 iCloud Drive 完全一致：

### 5.1 按需下载与状态图标

| 图标 / 状态 | 含义说明 | 占用本地空间 |
| :---: | :--- | :---: |
| ☁️ **云朵图标** | **云端占位文件**。仅同步了文件名、大小和元数据，未下载实际数据内容。 | 0 字节 |
| ⏳ **进度环** | **正在下载/同步**。双击或被其他程序读取时触发流式拉取。 | 增长中 |
| ✅ **无云朵/已就绪** | **已物化（Hydrated）文件**。数据已完整保存在本地高速缓存中。 | 实际大小 |
| 🔄 **刷新中** | **正在向远端提交写入**。本地修改正在上传到 WebDAV 服务器。 | 实际大小 |

### 5.2 释放本地磁盘空间

当本地存储空间不足时，可随时释放已经下载的文件，而不会影响云端数据：
- 在 Finder 中找到已下载的文件或文件夹；
- 右键点击，在上下文菜单中选择 **“移除下载内容” (Remove Download)**；
- 文件将立即转回 ☁️ 云端占位状态，释放本地占用的磁盘空间。

### 5.3 离线编辑与自动恢复

- **离线修改**：在无网络环境下，对已下载文件的修改会直接写入本地 SQLite WAL 暂存代次。
- **联网重试**：网络恢复后，后台同步调度器自动识别在途代次并推送至 WebDAV。
- **并发冲突防护**：上传时会自动校验服务端的 `ETag`。如果该文件在云端已被其他设备修改（HTTP 412），CloudDrive 不会覆盖云端内容，而是自动生成分叉副本（如 `filename (Conflict-xxxx).ext`），彻底避免数据静默丢失。

---

## 6. 菜单栏与快捷控制

- **菜单栏图标**：点击 macOS 右上角状态栏图标可查看：
  - 各个保险库的在线状态与锁定状态；
  - 最近同步任务与传输状态；
  - 快速打开对应保险库在 Finder 中的挂载根目录；
  - 锁定 / 卸载保险库。
- **实时日志**：在主界面或菜单栏中打开“系统日志”，可实时追踪 WebDAV 请求详细耗时、HTTP 状态码及同步状态机流转。

---

## 7. 常见问题排查 (FAQ)

### Q1: 安装后在 Finder 侧边栏没有看到保险库？
1. 打开系统 **“访达” -> “设置” -> “边栏”**，确保勾选了 **“云端宗卷” / “Cloud Storage”**。
2. 检查系统扩展是否成功注册：
   ```bash
   pluginkit -m -v -i net.aabg.CloudDrive.FileProvider
   ```
3. 重启 Finder 与 FileProvider 守护进程：
   ```bash
   killall -9 fileproviderd Finder
   ```

### Q2: 提示“无法连接至 WebDAV 服务器”？
- 确认输入的 URL 协议前缀（`http://` 或 `https://`）。
- 若使用局域网自签名 HTTPS 证书，建议确保证书已被系统钥匙串信任。
- 确认 WebDAV 服务端允许 `PROPFIND`、`GET`、`PUT`、`MKCOL`、`MOVE` 等标准 HTTP 方法。

### Q3: 如何完全卸载应用与清理本地同步元数据？
运行以下命令卸载应用并清理本地缓存与数据库：
```bash
# 1. 退出进程
killall -9 CloudDrive CloudDriveFileProvider 2>/dev/null || true

# 2. 移除应用
sudo rm -rf /Applications/CloudDrive.app

# 3. 清理本地 App Group 容器与 SQLite 数据库
rm -rf ~/Library/Group\ Containers/group.net.aabg.CloudDrive
```
