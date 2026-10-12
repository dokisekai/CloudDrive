# WebDAV 同步审查与修复记录

日期：2026-10-04；续审：2026-10-05。范围：当前工作区，包含此前未提交修改。由主线程与三个 agent 分别审查协议安全、同步一致性、队列性能，完成首轮修复、第二轮复审及交叉复审。

最新 Finder 状态、低成本复制移动与目录删除见 [续审记录](file-provider-status-copy-delete-audit-2026-10-05.md)。下文保留前几轮审查历史；当前目录删除规则以续审记录为准。

## 当前协议范围

应用仅提供 WebDAV。S3、SMB、FTP、123 云盘、本地文件夹不能通过存储工厂连接，也不会自动挂载。历史配置和驱动代码保留以兼容配置读取、测试夹具；没有删除已有用户数据。旧本地 WebDAV 自动桥接入口已移除。

## 已修复

| 审查点 | 原风险 | 修复 |
| --- | --- | --- |
| 跨数据库事务 | 元数据与队列跨库崩溃窗口 | 可恢复预写提交日志（SyncCommitJournal + JournalRecovery），崩溃重放自动前滚/回滚 |
| 上传丢失确认 | PUT 服务端落盘后断网丢响应致重试 412 | 同一强 ETag 下逐字节内容核验机制（UploadProof），核实内容一致后安全前滚 |
| 删除内容备份 | 脏删除仅保留临时文件缺乏恢复机制 | 持久化恢复清单与校验备份存储（DeletedPayloadBackupStore），防路径穿越与内容篡改 |
| 缓存 CAS 竞态 | 边算哈希边拷贝可变源文件可能污染 CAS | 写入前强制生成不可变快照，再做哈希校验与 CAS 链接；元数据损坏时熔断驱逐保护 |
| 新建与编辑 | 缺少 ETag 的普通/加密上传可能无条件覆盖 | 缺少版本只允许 create-if-absent；修改使用条件版本 |
| 删除与移动 | 队列记录版本但执行未使用 | 条件执行，缺少可靠版本时阻塞；上传完成后向删除/MOVE 后继传播版本；直接映射目录移动不强求文件 ETag |
| 冲突恢复 | 复制/下载失败仍确认成功并清旧任务 | 错误传播、持久化分叉副本、只清捕获的旧任务 |
| 并发编辑 | 恢复下载与旧元数据覆盖新编辑 | 独立下载暂存、提交锁与新任务检测、保留新缓存与元数据 |
| Finder 确认 | 部分队列持久化错误被忽略 | 保存/删除主链路传播错误；删除先保留脏内容，再登记意图 |
| 上传取消 | 查询未开始任务后删除可能与领取竞态 | SQL CAS 只取消捕获且未开始的任务；保留活动传输字节 |
| 落盘 | 暂存拷贝与数据库提交不保证断电持久性 | 暂存同步写盘及目录 fsync；队列与同步元数据 FULL |
| 大队列 | 每项反复读取解码整队列 | 索引选取、持久化依赖、SQL 更新后继版本、永久失败候选过滤 |
| 并发与重启 | 丢唤醒、旧重试计时覆盖、新领取竞态 | 锁内结束调度与重试、CAS 领取、独占消费者立即恢复遗留领取 |
| 数据库错误 | SQL 错误当空结果；多语句 schema 只执行第一句 | 必要读写抛错、独立建立索引、连接毒化后安全回滚和阻断泄漏 |
| 目录对账 | 旧快照覆盖待上传状态/版本，上传读取可变源文件 | 保留待同步与 localOnly，使用旧 ETag 基线，不可变暂存后入队 |
| 目录前缀 | `%` / `_` 被当 SQL 通配符导致误删元数据 | 字面路径前缀匹配 |
| WebDAV XML | 实体、越界/跨域 href、重复条目、伪造名称 | 严格 XML、路径和响应校验 |
| WebDAV 207 | 空或损坏 mutation 响应可能确认成功 | 必须完整 multistatus，逐项确认状态 |
| 网络与内存 | 重定向、弱 ETag、超大 Range/目录响应 | 拒绝重定向、拒绝弱版本条件、Range 严格校验与大小限制、PROPFIND 64 MiB 上限 |
| 目录探测 | 大目录创建大量并发任务 | 每批最多 8 项探测 |

## 验证

以下为第三轮完成时的验证记录；最新 30 个回归套件验证见 Finder 续审记录。

`swift build`：全部通过，包括主应用、File Provider 扩展以及测试执行套件。

`./scripts/test.sh`：**全部通过（Exit Code 0）**。
- `runTests()`：158 / 158 项单元测试全部通过。
- 26 个专用可靠性回归测试套件全部通过：
  - `runStorageAvailabilityRegressionTests`（仅允许 WebDAV，非 WebDAV 安全屏蔽）
  - `runSQLiteTransactionRegressionTests`（事务嵌套 Savepoint、失败回滚与句柄毒化恢复）
  - `runContentRevisionRegressionTests`（修订版本标识与跨进程元数据版本令牌）
  - `runDatabaseSecurityRegressionTests`
  - `runWebDAVRegressionTests`
  - `runWebDAVBoundaryRegressionTests`（响应编码、短 Range、XML 与 MKCOL 路径边界）
  - `runSyncRegressionTests`
  - `runSyncSafetyRegressionTests`
  - `runSyncSaveAcceptanceRegressionTests`（16 并发保存仅一个赢家、暂存提交恢复及嵌套锁释放）
  - `runSyncCommitJournalRegressionTests`（5 个故障注入点跨库提交恢复）
  - `runUploadVerificationRegressionTests`（响应丢失后内容核验证明恢复）
  - `runWebDAVUploadProofRegressionTests`
  - `runVFSMutationRevisionRegressionTests`（直接 VFS 删除、移动的条件版本与冲突保护）
  - `runDeletedPayloadRecoveryRegressionTests`（未同步脏内容导出与校验清理）
  - `runDirectoryReconciliationRegressionTests`
  - `runQueueSchedulingRegressionTests`
  - `runQueueVersionPerformanceRegressionTests`（同文件版本、加密身份转移和删除保护）
  - `runCacheRegressionTests`
  - `runCacheIntegrityRegressionTests`（缓存快照与损坏元数据保护）
  - `runDataSafetyRegressionTests`
  - `runRecycleBinRegressions`
  - `runCryptomatorRandomAccessRegressionTests`
  - `runItemAliasStoreRegressionTests`
  - `runFileOpenSyncStatusRegressionTests`
  - `runVaultLockUnlockRegressionTests`
  - `runExcludeSyncRegressionTests`

## 续审补充

- SQLite 多语句完整执行，嵌套事务使用保存点；提交或回滚失败不会继续使用状态不确定的连接。
- 同一文件队列依赖由全部前驱改为最近前驱链；取消中间项会继承未完成前驱，避免绕过活动上传。1,000 个版本仅保留 999 条依赖边。
- Finder 内容读取按请求 ETag 绑定版本；本地快照和返回版本在提交锁内生成，下载提交前检查是否出现新编辑。部分读取使用有溢出检查的区间及分块写入。
- 删除备份有独立清单、哈希校验和导出接口；未导出副本不自动清理。加密长名称文件只条件删除内容，保留包装目录，避免误删其他客户端新建内容。
- 本次 WebDAV 专项测试中，10,000 个被依赖阻塞项加 1,000 个可运行项排空约 0.326 秒；10,000 个永久失败项加 1,000 个可运行项约 3.327 秒。它们是本机单次结果，不能代表公网吞吐。

## 第三轮复审（2026-10-05）

- 同线程、同规范提交锁路径的同步闭包可安全重入；跨线程与跨进程仍排他。并发保存将版本校验、完整元数据和队列接受放入一次可恢复提交，未接受的新文件记录也能按精确快照回滚。
- 缓存读取不再持有内存锁等待文件锁，避免与驱逐检查互相等待。驱逐统一采用提交锁再获取非阻塞独占租约；缓存删除与 clean→cloudOnly 持久化在同一锁内执行。
- 目录缓存逐文件保护 pending、pinned 和正在读取的内容；根目录固定保留策略覆盖子项。目录缓存移动失败抛错，不再移动元数据后假装成功。
- 第三轮曾阻断远端目录删除；最新续审按用户要求改为服务端单次 collection DELETE，加密目录解除父入口引用，不在客户端递归删子项。结果不确定时停止自动重试，详见续审记录。
- 同文件完成只更新最近后继 ETag 和状态；MOVE 源查询使用独立索引；身份替换合并依赖重建，同身份完成跳过全队列扫描。
- WebDAV 拒绝非 EOF 短 Range 与非 identity 内容编码。XML 增加字节级 DTD 检查、namespace/root/depth/property 限制；控制请求响应有 64 MiB 限制。
- PUT 使用持久化上传协调器流式丢弃响应体，响应声明或实际字节超过 1 MiB 即取消；支持无 Content-Length、任务取消和拒绝重定向。连接日志不再打印完整配置 URL。207 变更响应要求正确 DAV 命名空间和逐项状态，拒绝孤立 status 确认。
- MKCOL 在任何网络动作前校验完整路径，相对配置根目录逐级创建；405 必须证明目标为目录。配置 base URL 拒绝编码路径穿越。
- 上传完成只删除没有任何 metadata 引用的暂存路径；local_path 查询有索引。缓存发布失败时读取优先采用匹配版本的暂存副本，成功发布缓存后在锁内切换引用，释放正常上传的暂存文件。
- FileProvider 保存使用持久化暂存路径；关键 metadata 读取和写入失败传播。部分内容读取按有界块读取已打开的本地文件，避免因克隆不可用而先复制整份大文件。

已执行本机专项回归：1,000 同文件版本 enqueue/complete 约 0.089/0.413 秒；10,000 版本约 0.964/8.633 秒；3,000 加密身份转移及完成约 0.970/1.499 秒。结果为单次数据库测试，不代表网络传输速率。

## 尚未完成的验证与限制

1. 不能据此保证项目不存在性能或安全问题。尚未完成真实 WebDAV 服务端、多 Mac 并发及 Finder 长时间压力测试；当前依据是本机回归、模拟服务端和故障注入。
2. 单次目录 DELETE 是整目录授权操作，无法用一个 ETag 证明所有子项没有并发变化；加密目录 unlink 保留孤立子密文，尚无自动远端垃圾回收。恢复备份已有核心接口，尚无完整用户恢复界面。
3. 大队列性能结果来自本机数据库测试，尚未包含真实网络、磁盘空间不足和多进程长时间运行的组合压力。
4. 上传不确定结果核验会增加下载成本；无法证明远端字节与本地快照一致时保留失败或冲突，不确认成功。
5. 依赖服务端正确执行条件请求并提供强 ETag。拒绝弱版本、跨域重定向和不合规响应；服务端实现及 TLS 部署需在实际环境验证。
6. 极端缓存或元数据写入失败时，为避免丢失最新字节会保留已确认上传的暂存副本；尚无完整自动回收流程，需后续按持久化引用与恢复清单设计清理。
