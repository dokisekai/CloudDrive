# CloudDrive 日志系统

## 概述

CloudDrive 使用统一的日志管理系统，支持多个独立的日志文件，便于调试和问题追踪。

## 日志文件位置

所有日志文件存储在：`~/.CloudDrive/Logs/`

## 日志文件类别

系统会自动创建以下独立的日志文件：

### 1. 系统日志 (system-YYYY-MM-DD.log)
- **用途**: 应用启动、配置、系统级事件
- **内容**: 
  - 应用启动/关闭
  - 配置加载
  - 系统初始化
  - 保险库管理

### 2. 文件操作日志 (file-operations-YYYY-MM-DD.log)
- **用途**: 所有文件相关操作
- **内容**:
  - 文件下载/上传
  - 文件创建/删除/修改
  - 文件移动/复制
  - 目录操作
  - FileProvider 扩展的所有文件操作

### 3. WebDAV 日志 (webdav-YYYY-MM-DD.log)
- **用途**: WebDAV 网络通信
- **内容**:
  - HTTP 请求/响应
  - 连接状态
  - 认证信息
  - 网络错误

### 4. 缓存日志 (cache-YYYY-MM-DD.log)
- **用途**: 本地缓存管理
- **内容**:
  - 缓存命中/未命中
  - 文件缓存/清理
  - 缓存策略变更
  - 缓存统计信息

### 5. 数据库日志 (database-YYYY-MM-DD.log)
- **用途**: 数据库操作
- **内容**:
  - SQL 查询
  - 数据库初始化
  - 数据迁移
  - 数据库错误

## 日志级别

- **DEBUG**: 详细的调试信息
- **INFO**: 一般信息
- **WARNING**: 警告信息
- **ERROR**: 错误信息
- **SUCCESS**: 成功操作

## 使用方法

### 在代码中记录日志

```swift
import CloudDriveCore

// 系统日志
logInfo(.system, "应用启动")
logError(.system, "配置加载失败")

// 文件操作日志
logInfo(.fileOps, "开始下载文件: \(filename)")
logSuccess(.fileOps, "文件下载完成")

// WebDAV 日志
logInfo(.webdav, "发送 HTTP GET 请求")
logError(.webdav, "HTTP 错误: 404")

// 缓存日志
logInfo(.cache, "缓存命中: \(fileId)")
logWarning(.cache, "缓存超限，开始清理")

// 数据库日志
logInfo(.database, "执行查询: SELECT * FROM files")
logError(.database, "数据库错误: \(error)")
```

### 日志格式

```
[2025-12-27T04:15:00.000Z] [INFO] 日志消息内容 (文件名.swift:行号)
```

## 日志轮转

- **触发条件**: 单个日志文件超过 10MB
- **轮转方式**: 重命名为 `category-timestamp.log`
- **保留策略**: 保留最近 5 个日志文件
- **自动清理**: 删除超过 5 个的旧日志文件

## 查看日志

### 方法 1: 命令行
```bash
# 查看系统日志
tail -f ~/.CloudDrive/Logs/system-2025-12-27.log

# 查看文件操作日志
tail -f ~/.CloudDrive/Logs/file-operations-2025-12-27.log

# 查看所有日志
tail -f ~/.CloudDrive/Logs/*.log
```

### 方法 2: 控制台应用
打开 macOS 控制台应用，搜索 "CloudDrive"

### 方法 3: 代码获取路径
```swift
let logPath = Logger.shared.getLogFilePath(for: .fileOps)
print("文件操作日志: \(logPath ?? "未找到")")
```

## 调试技巧

### 1. 追踪文件下载问题
查看以下日志文件：
- `file-operations-*.log` - 文件操作流程
- `webdav-*.log` - 网络请求详情
- `cache-*.log` - 缓存状态

### 2. 追踪 404 错误
```bash
grep "404" ~/.CloudDrive/Logs/webdav-*.log
```

### 3. 查看缓存统计
```bash
grep "缓存统计" ~/.CloudDrive/Logs/cache-*.log
```

### 4. 查看所有错误
```bash
grep "ERROR" ~/.CloudDrive/Logs/*.log
```

## 性能考虑

- 日志写入是异步的，不会阻塞主线程
- 使用专用队列处理日志写入
- 自动轮转避免单个文件过大
- 旧日志自动清理节省空间

## 隐私和安全

- 日志文件存储在用户目录，只有用户可访问
- 不记录密码等敏感信息
- WebDAV 认证只记录用户名，不记录密码
- 可以安全地分享日志文件用于调试

## 故障排除

### 问题: 日志文件未创建
**解决方案**: 检查目录权限
```bash
ls -la ~/.CloudDrive/Logs/
```

### 问题: 日志文件过多
**解决方案**: 手动清理旧日志
```bash
rm ~/.CloudDrive/Logs/*-[0-9]*.log
```

### 问题: 找不到特定操作的日志
**解决方案**: 检查正确的日志类别
- 文件操作 → file-operations
- 网络请求 → webdav
- 缓存操作 → cache

## 最佳实践

1. **使用正确的日志类别**: 确保日志记录到正确的文件
2. **提供足够的上下文**: 包含文件名、ID、路径等关键信息
3. **使用适当的日志级别**: 
   - 正常操作用 INFO
   - 潜在问题用 WARNING
   - 失败操作用 ERROR
   - 成功完成用 SUCCESS
4. **避免过度日志**: 不要在循环中记录大量日志
5. **包含错误详情**: 记录错误时包含完整的错误信息

## 示例：完整的文件下载日志流程

```
[file-operations] 开始获取文件内容
[file-operations] Item ID: /documents/report.pdf
[file-operations] 本地缓存路径: ~/.CloudDrive/Cache/documents/report.pdf
[cache] 缓存未命中: /documents/report.pdf
[file-operations] 从远程下载
[webdav] 开始下载文件
[webdav] 完整 URL: https://webdav.example.com/documents/report.pdf
[webdav] 发送 HTTP GET 请求...
[webdav] 收到响应 - 状态码: 200
[webdav] 下载成功
[file-operations] 下载完成到临时文件
[file-operations] 移动到缓存...
[cache] 文件已缓存: /documents/report.pdf
[cache] 大小: 1048576 字节, 策略: automatic
[file-operations] 文件获取成功
```

## 未来改进

- [ ] 添加日志搜索功能
- [ ] 支持日志导出
- [ ] 添加日志分析工具
- [ ] 支持远程日志收集（可选）
- [ ] 添加日志可视化界面