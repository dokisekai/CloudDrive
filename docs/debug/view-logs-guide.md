# CloudDrive 日志查看指南

本文档提供了查看 CloudDrive 及其相关服务日志的完整指南。

## 目录

- [实时日志查看](#实时日志查看)
- [历史日志查看](#历史日志查看)
- [错误日志过滤](#错误日志过滤)
- [使用项目脚本](#使用项目脚本)
- [常见问题排查](#常见问题排查)

---

## 实时日志查看

### CloudDrive 主应用

查看主应用的实时日志：

```bash
log stream --predicate 'process == "CloudDrive"' --level debug
```

### CloudDriveFileProvider Extension

查看 FileProvider Extension 的实时日志：

```bash
log stream --predicate 'processImagePath CONTAINS "CloudDriveFileProvider"' --level debug
```

### FileProvider 系统服务

查看系统 FileProvider 守护进程的日志：

```bash
log stream --predicate 'process == "fileproviderd"' --level debug
```

### FileProvider 框架

查看 Apple FileProvider 框架的日志：

```bash
log stream --predicate 'subsystem == "com.apple.FileProvider"' --level debug
```

### 所有 FileProvider 相关进程

查看所有包含 "FileProvider" 的进程日志：

```bash
log stream --predicate 'processImagePath CONTAINS "FileProvider"' --level debug
```

### WebDAV 相关日志

查看 WebDAV 网络请求相关日志：

```bash
log stream --predicate 'eventMessage CONTAINS "WebDAV"' --level debug
```

---

## 历史日志查看

### 查看最近 1 小时的日志

```bash
# 主应用
log show --last 1h --predicate 'process == "CloudDrive"'

# FileProvider Extension
log show --last 1h --predicate 'processImagePath CONTAINS "CloudDriveFileProvider"'
```

### 查看最近 10 分钟的日志

```bash
log show --last 10m --predicate 'processImagePath CONTAINS "CloudDriveFileProvider"'
```

### 查看今天的日志

```bash
log show --start today --predicate 'subsystem == "com.apple.FileProvider"'
```

### 查看特定时间段的日志

```bash
# 从昨天到现在
log show --start yesterday --predicate 'process == "CloudDrive"'

# 从特定时间开始
log show --start "2025-01-04 10:00:00" --predicate 'process == "CloudDrive"'
```

### 保存日志到文件

```bash
# 保存最近 1 小时的日志
log show --last 1h --predicate 'process == "CloudDrive"' > clouddrive_logs.txt

# 保存今天的日志
log show --start today --predicate 'processImagePath CONTAINS "CloudDriveFileProvider"' > fileprovider_logs.txt
```

---

## 错误日志过滤

### 查看所有错误日志

```bash
# 查看所有进程的错误
log show --predicate 'eventMessage CONTAINS "ERROR"' --last 1h

# 只看 CloudDrive 的错误
log show --predicate 'process == "CloudDrive" AND eventMessage CONTAINS "ERROR"' --last 1h
```

### 查看特定错误

#### 用户交互错误

```bash
log show --predicate 'eventMessage CONTAINS "user interactions"' --last 1h
```

#### 文件上传错误

```bash
log show --predicate 'eventMessage CONTAINS "upload" AND eventMessage CONTAINS "ERROR"' --last 1h
```

#### 文件创建错误

```bash
log show --predicate 'eventMessage CONTAINS "create" AND eventMessage CONTAINS "ERROR"' --last 1h
```

#### WebDAV 错误

```bash
log show --predicate 'eventMessage CONTAINS "WebDAV" AND eventMessage CONTAINS "ERROR"' --last 1h
```

### 查看警告日志

```bash
log show --predicate 'eventMessage CONTAINS "WARNING"' --last 1h
```

---

## 使用项目脚本

项目提供了便捷的日志查看脚本，位于 `scripts/debug/` 目录。

### view-app-logs.sh

查看 CloudDrive 主应用的日志：

```bash
./scripts/debug/view-app-logs.sh
```

### view-fileprovider-logs.sh

查看 FileProvider Extension 的日志：

```bash
./scripts/debug/view-fileprovider-logs.sh
```

### run-with-debug.sh

运行应用并查看日志：

```bash
./scripts/debug/run-with-debug.sh
```

### launch-with-debug.sh

启动应用并开启调试模式：

```bash
./scripts/debug/launch-with-debug.sh
```

---

## 多终端监控

为了全面监控所有服务，建议在多个终端窗口中同时运行日志命令：

### 终端 1 - CloudDrive 主应用

```bash
log stream --predicate 'process == "CloudDrive"' --level debug
```

### 终端 2 - FileProvider Extension

```bash
log stream --predicate 'processImagePath CONTAINS "CloudDriveFileProvider"' --level debug
```

### 终端 3 - FileProvider 系统服务

```bash
log stream --predicate 'process == "fileproviderd"' --level debug
```

### 终端 4 - FileProvider 框架

```bash
log stream --predicate 'subsystem == "com.apple.FileProvider"' --level debug
```

---

## 日志级别说明

macOS 日志系统支持以下级别：

- `debug` - 调试信息
- `info` - 一般信息
- `notice` - 重要通知
- `error` - 错误信息
- `fault` - 严重错误

默认情况下，`log stream` 和 `log show` 会显示 `info` 及以上级别的日志。要查看更详细的调试信息，使用 `--level debug` 参数。

---

## 常见问题排查

### 问题 1: 看不到 FileProvider Extension 的日志

**可能原因：**
- Extension 进程未启动
- 日志被过滤

**解决方案：**

1. 检查 Extension 是否运行：
```bash
ps aux | grep CloudDriveFileProvider
```

2. 使用更宽松的过滤条件：
```bash
log stream --predicate 'processImagePath CONTAINS "CloudDrive"' --level debug
```

3. 使用 Console.app 查看：
```bash
open /System/Applications/Utilities/Console.app
```

### 问题 2: 日志输出太多

**解决方案：**

1. 只查看特定级别的日志：
```bash
log stream --predicate 'process == "CloudDrive"' --level error
```

2. 过滤特定关键词：
```bash
log stream --predicate 'process == "CloudDrive" AND eventMessage CONTAINS "upload"'
```

3. 保存到文件并使用 grep 过滤：
```bash
log stream --predicate 'process == "CloudDrive"' --level debug > logs.txt &
grep "ERROR" logs.txt
```

### 问题 3: 无法查看历史日志

**可能原因：**
- 日志被清理
- 时间范围不正确

**解决方案：**

1. 检查日志保留时间：
```bash
log config --status
```

2. 使用更大的时间范围：
```bash
log show --last 24h --predicate 'process == "CloudDrive"'
```

### 问题 4: 上传失败时如何查看日志

**步骤：**

1. 在终端 1 启动 WebDAV 日志监控：
```bash
log stream --predicate 'eventMessage CONTAINS "WebDAV"' --level debug
```

2. 在终端 2 启动 FileProvider 日志监控：
```bash
log stream --predicate 'processImagePath CONTAINS "CloudDriveFileProvider"' --level debug
```

3. 在 Finder 中尝试上传文件

4. 观察两个终端的输出，查找错误信息

---

## 日志分析技巧

### 查找特定操作的完整流程

```bash
# 查找文件上传的完整流程
log show --last 1h --predicate 'eventMessage CONTAINS "upload"' | grep -E "(开始|完成|成功|失败|ERROR)"
```

### 统计错误数量

```bash
log show --last 1h --predicate 'eventMessage CONTAINS "ERROR"' | wc -l
```

### 查找时间戳

```bash
log show --last 1h --predicate 'process == "CloudDrive"' | grep "2025-01-04"
```

### 导出特定错误

```bash
log show --last 1h --predicate 'eventMessage CONTAINS "user interactions"' > user_interactions_error.txt
```

---

## 进阶用法

### 使用正则表达式过滤

```bash
# 查找包含数字的错误
log show --last 1h --predicate 'eventMessage MATCHES "ERROR.*[0-9]+"'
```

### 组合多个条件

```bash
# 查找 CloudDrive 的错误或警告
log show --last 1h --predicate 'process == "CloudDrive" AND (eventMessage CONTAINS "ERROR" OR eventMessage CONTAINS "WARNING")'
```

### 实时过滤并高亮

```bash
# 高亮显示错误信息
log stream --predicate 'process == "CloudDrive"' --level debug | grep --color=always -E "ERROR|WARNING|SUCCESS"
```

---

## 参考资源

- [Apple 日志文档](https://developer.apple.com/documentation/os/logging)
- [log 命令手册](https://ss64.com/osx/log.html)
- [Console.app 使用指南](https://support.apple.com/guide/console/welcome/mac)

---

## 更新日志

- 2025-01-04: 初始版本
