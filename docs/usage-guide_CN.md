# CloudDrive 使用与操作指南 (Usage Guide)

> 当前版本仅启用 WebDAV；其他协议的历史配置不会连接或自动挂载。请填写最终 WebDAV 地址，重定向响应将被拒绝。

> **Native macOS File Provider for Cryptomator + WebDAV — encrypted files appear directly in Finder and download only when opened. Free and open source.**  
> **面向 Cryptomator + WebDAV 的原生 macOS File Provider — 加密文件直接在访达 (Finder) 中显示，仅在打开时按需流式下载。完全免费且开源。**  
> 🔗 **项目开源地址 (GitHub)**: [https://github.com/dokisekai/CloudDrive](https://github.com/dokisekai/CloudDrive)

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
| **Cryptomator 官方标准** | ✅ 100% 完全兼容 | 严格实现 Vault Format 7/8/9 官方规范（AES-256-GCM、Scrypt、Base32 文件名加密与目录打散），与官方桌面端及移动端双向读写完全互通。 |
| **按需下载 (Hydration)** | ✅ 生产就绪 | 利用 macOS File Provider 原生 Dataless Files，初次仅拉取目录树元数据，按需流式下载，节省本地磁盘。 |
| **不可变代次与防冲突** | ✅ 生产就绪 | 每次编辑生成不可变代次，写入携带 ETag 条件头（`If-Match` / `If-None-Match`），出现版本竞争自动分叉保留副本。 |
| **缓存管理与空间释放** | ✅ 生产就绪 | 支持右键“移除下载内容”释放本地磁盘占用；具备 LRU 缓存租约防误删机制。 |
| **S3 / SMB / FTP** | ⏳ 演进中 | 代码库已包含协议驱动骨架，后续版本逐步开放端到端验证。 |

---

## 2. 准备工作与系统要求

- **操作系统**：**macOS 15.0 (Sequoia) 或更高版本**。
- **硬件平台**：**Universal 2 通用二进制架构**，原生支持 Apple Silicon (M1/M2/M3/M4) 及 Intel (x86_64) Mac。
- **开发工具**：Xcode 16+（仅源码构建需要；使用预编译包则无需安装）。
- **代码签名**：**无需付费 Apple 开发者账号**。激活与构建脚本会自动适配个人证书或回退到 Ad-hoc 自签名 (`-`) 并正确绑定 App Group 沙盒权限。
- **权限要求**：构建与安装需要管理员权限（向 `/Applications` 写入并注册系统级 `FileProvider` 扩展）。

---

## 3. 安装与首次配置

### 3.1 方案 A：预编译版本本地激活（免 Xcode，推荐普通用户）

适用于直接下载 Releases 预编译包（`CloudDrive-macOS-Release.zip`）的用户：
> 官方分发包已打包为包含 `arm64` 与 `x86_64` 的通用二进制，任何 Mac 设备均可原生流畅运行。

1. 解压并将 `CloudDrive.app` 拷贝到 `/Applications` 目录；
2. 运行本地激活脚本：
   ```bash
   bash activate.sh
   # 或者在仓库内运行：./scripts/activate.sh
   ```
脚本将在 2 秒内自动清除下载隔离标记（解决“已损坏，移到废纸篓”问题），就地执行本机 Ad-hoc 签名并注入 App Group 沙盒特权，完成系统扩展注册。

### 3.2 方案 B：源码一键构建与安装（适合开发者，需 Xcode 16+）

在仓库根目录下运行自动化构建与注册脚本：

```bash
./scripts/install.sh
# 如需编译 Universal (arm64 + x86_64) 通用版：
# ./scripts/install.sh --universal
```

脚本将自动执行以下操作：
1. 校验 Xcode 开发工具链与 SPM 依赖；
2. 自动修补相关第三方加密库的已知边界问题；
3. 构建主程序 `CloudDrive.app` 与核心扩展 `CloudDriveFileProvider.appex`；
4. 完成本地代码签名与权限沙盒（App Sandbox + App Group）绑定；
5. 安装至 `/Applications/CloudDrive.app` 并注册到系统的 `fileproviderd` 服务。

> **发布者提示**：若需要生成面向其他无 Xcode 用户的分发包，可在本机运行：
> ```bash
> ./scripts/package.sh
> ```
> 构建产物将打包为 `build/CloudDrive-macOS-Release.zip`，内含 `CloudDrive.app` 与自包含激活脚本。

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

### 4.4 场景四（强烈推荐）：搭配 Alist 实现“全网盘 + Cryptomator 终极体验”

[Alist](https://github.com/alist-org/alist) 是一款强大的聚合文件列表工具，可将数十种主流网盘（百度网盘、夸克网盘、阿里云盘、115、OneDrive、Google Drive、PikPak、天翼云等）统一映射为标准的 WebDAV 接口。

通过 **CloudDrive + Alist + Cryptomator** 组合，即可实现全网盘的“原生体验 + 零知识加密”：
1. **在 Alist 中挂载目标网盘**（例如将百度网盘挂载到 `/baidu`，或将阿里云盘挂载到 `/aliyun`）；
2. **在 CloudDrive 中创建加密保险库**：
   - WebDAV 地址填写 Alist 的 WebDAV 端点（通常为 `http://localhost:5244/dav/` 或您的 NAS 地址）；
   - 输入 Alist 的账号密码；
   - 远端路径指向对应网盘目录（如 `/aliyun/SecureVault`）；
3. **享受极致体验**：
   - **隐私绝对可控**：数据在离开 Mac 本机前已完成 AES-256-GCM 加密，网盘服务商只能看到密文切片，无法扫描或封禁敏感文件；
   - **免装臃肿客户端**：无需安装各大网盘的官方臃肿客户端，全部通过原生访达（Finder）统一管理；
   - **零本地硬盘负担**：数 TB 文件随点随看，流式按需物化，关闭即可释放空间。

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
