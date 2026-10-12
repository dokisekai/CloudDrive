# CloudDrive 多协议存储能力与限制矩阵 (Storage Matrix)

当前版本仅启用 WebDAV。S3、SMB、FTP、123 云盘和本地文件夹均不能通过应用或存储工厂连接；旧配置保留但不自动挂载。下表及其他协议章节仅作为历史设计参考，不代表当前可用功能。

WebDAV 必须配置最终地址（客户端拒绝重定向），更新需要强 ETag，Range 必须得到有效的 206 响应。

---

## 1. 协议能力对比总览

| 能力项 | WebDAV | Amazon S3 / 兼容对象存储 | SMB / Windows 共享 | FTP / FTPS | 本地文件夹 (Local) |
|---|---|---|---|---|---|
| **条件写入 (If-Match)** | ✅ 原生支持 (RFC 4918) | ⚠️ 部分支持 (新版 S3/MinIO) | ❌ 不支持 (需应用层锁) | ❌ 不支持 | ❌ 不支持 (本地代次对比) |
| **创建防重 (If-None-Match)** | ✅ 原生支持 | ⚠️ 部分支持 (新版 S3) | ❌ 不支持 | ❌ 不支持 | ✅ 原生 (`.withoutOverwriting`) |
| **覆盖写原子性** | ✅ 协议支持 | ✅ 对象覆盖天然原子 | ⚠️ 需同卷临时文件原子替换 | ❌ 覆盖中途失败损坏原文件 | ✅ 原子替换 (`atomic`) |
| **目录移动原子性** | ✅ MOVE 跨目录 | ❌ 无目录实体，需多对象搬迁 | ✅ 原生移动 | ❌ 依赖多级重命名 | ✅ 原生重命名 |
| **目录枚举分页** | ❌ 单次响应 (长列表慢) | ⚠️ 必须处理续页 Token (1000项) | ❌ 流式/缓冲枚举 | ❌ 全量文本解析 | ❌ 本地枚举 |
| **断点续传 / 范围读 (Range)** | ✅ 支持 (HTTP 206) | ✅ 支持 (HTTP 206) | ✅ 支持 (文件指针 seek) | ⚠️ 依赖 REST 命令 | ✅ 原生支持 |
| **ETag 强校验** | ✅ 服务端计算 | ✅ MD5 / 分块校验和 | ❌ 依赖 mtime + size 模拟 | ❌ 依赖 mtime + size | ❌ 本地 SHA-256 模拟 |
| **Cryptomator 格式兼容** | ⭐️ 官方第一级推荐 | ✅ 良好支持 | ✅ 支持 | ⚠️ 兼容性脆弱 | ⭐️ 官方第一级推荐 |
| **作为主存储生产推荐** | **推荐** | **推荐** | **可用 (注意挂载边界)** | **只读/实验性 (不推荐写入)** | **推荐** |

---

## 2. 各协议深入规范与防御要求

### 2.1 WebDAV 协议防御标准

WebDAV 是 CloudDrive 和 Cryptomator 的首选协议，但必须严格遵循 RFC 4918 规范：

1. **条件请求与 412 处理**：
   - 上传修改必须携带 `If-Match: "<base_etag>"`。
   - 新建文件必须携带 `If-None-Match: *`。
   - 收到 `412 Precondition Failed` 时，严禁自动剥离条件头重新无条件覆盖，必须转入冲突分叉流程。
2. **207 Multi-Status 逐项解析**：
   - 批量操作、递归删除或 PROPFIND 返回 `HTTP 207 Multi-Status` 时，必须逐个解析 `<d:response>` 中的 `<d:status>`。
   - 只要有任何一个子项状态不为 `200..299`，必须将该子项记为失败，保留恢复清单，绝对不能仅凭主状态码 207 将整个目录标记为成功。
3. **URL 编码与路径边界**：
   - 服务端返回的 `href` 必须规范化解码，并校验是否处于当前保险库根路径围栏内。
   - 拒绝一切包含 `..`、空段或跨域主机名的 `Destination` 头。
4. **Alist 聚合网盘 WebDAV 适配**：
   - 完美适配 Alist 桥接的百度网盘、夸克、阿里云盘、115、OneDrive、Google Drive 等各色存储源生成的 WebDAV。
   - CloudDrive 在其之上构建 Cryptomator 零知识加密与按需物化下载，实现多网盘在访达中的统一原生管理。

### 2.2 S3 / 对象存储防御标准

对象存储（AWS S3、MinIO、Cloudflare R2 等）以扁平 Key-Value 形式组织数据，无物理目录概念：

1. **强制的分页延续 (Pagination Token Loop)**：
   - AWS S3 `ListObjectsV2` 默认单次最多返回 1,000 个 Key。
   - **防御规范**：必须在 `listDirectory` 中循环检查 `<IsTruncated>true</IsTruncated>`，使用 `<NextContinuationToken>` 持续拉取直至全部加载完毕。
   - **严禁截断判断为删除**：如果分页未遍历完全或中间抛错，禁止将未列出的已有本地记录误判为“已被远端删除”。
2. **目录移动与删除的多阶段检查点**：
   - 在 S3 中移动目录 `dirA/` 到 `dirB/` 实质是：枚举所有 `dirA/*` 对象 $\to$ 逐个 `CopyObject` 到 `dirB/*` $\to$ 逐个 `DeleteObject`。
   - **防御规范**：该流程不具备原子性。必须在本地 SQLite WAL 中登记多阶段检查点。在所有对象均确认复制到 `dirB` 之前，严禁删除 `dirA`。中断后重启必须能根据检查点幂等续做。

### 2.3 SMB / CIFS 共享存储防御标准

1. **挂载点名称冲突隔离**：
   - macOS 默认将共享挂载到 `/Volumes/<shareName>`。若用户添加了两台不同 NAS 上的同名共享 `Data`，系统可能自动挂载为 `/Volumes/Data-1`。
   - **防御规范**：不能以静态 `/Volumes/<share>` 判定挂载。必须生成基于 `host:port:share` 的 SHA-256 哈希命名空间，严格绑定已验证挂载路径，防止跨 NAS 串写。
2. **安全替换防数据丢失**：
   - **严禁**执行“先删除旧文件，再写入新文件”的流程（一旦写入失败，旧文件已丢失）。
   - **防御规范**：始终写入同目录的 `.tmp.<UUID>` 临时文件，执行 `fsync` 确保数据落盘后，调用底层 `replaceItemAtURL` 或 POSIX `rename` 原子替换目标。

### 2.4 FTP / FTPS 协议安全策略

1. **坚决消除错误当空列表 (Fail-Closed)**：
   - 历史代码在 URLSession 失败或解析异常时返回 `[]`，直接引发本地数据库清洗。
   - **防御规范**：网络断开、超时、控制连接断开或解析异常时，必须抛出 `StorageError.networkError`，禁止吞错返回空数组。
2. **定位建议**：
   - 由于 FTP 协议缺乏原子操作、缺少条件写入指令、且时间戳因服务端配置存在时区与秒级精度丢失，**建议将 FTP 设为“只读模式”或明确标记“实验性，不建议作为唯一工作区”**。

### 2.5 本地存储 (Local FileSystem)

1. **APFS 写时复制优化 (CoW Clone)**：
   - 对于本地目录保险库，在生成不可变 Payload 或制作交付副本时，优先调用 `clonefile(2)` 或 APFS Copy-on-Write 机制，实现零磁盘开销和瞬间交付。
2. **符号链接与沙盒逃逸防范**：
   - 检查所有操作的目标路径，必须在配置的本地存储根目录之内；解析符号链接真实路径（`resolvingSymlinksInPath`），拒绝指向根外的符号链接写入。

---

## 3. 错误分类与重试策略 (Error Handling & Backoff)

为确保存储层不会因为短暂网络波动或服务端限流导致同步队列死锁，统一实施分层错误分类：

```mermaid
flowchart TD
    Err[捕获 StorageError] --> Check{错误类型判断}
    
    Check -->|401/403/签名错误| Fatal[不可恢复错误 Fatal]
    Check -->|412 Precondition Failed| Conflict[版本冲突 Conflict]
    Check -->|网络瞬断 / 超时 / 500 / 502 / 503| Transient[临时错误 Transient]
    Check -->|404 Not Found| NotFound[对象不存在 NotFound]
    
    Fatal --> ActionFatal[暂停当前 Vault 队列，发出通知要求用户重新认证]
    Conflict --> ActionConflict[保留本地 Payload，进入冲突分叉处理，绝不丢弃]
    Transient --> ActionTransient[计算指数退避时间: min(300, 2^attempt) 秒，等待唤醒重试]
    NotFound --> ActionNotFound[核对本地删除意图或更新本地状态为已删除]
```

- **重试上限原则**：
  - 临时性网络错误（Transient）**绝不设置“超过 3 次就彻底删除任务”** 的规则。
  - 任务只能在失败后挂起（Suspended / Blocked）并保留完整的 Payload，等待网络状态恢复或用户手动点击“全部重试”。
