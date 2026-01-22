# CloudDrive 日志系统修复

## 问题描述

之前的日志系统存在以下问题：
1. **Xcode 运行时看不到文件操作日志** - 只能通过 `./test_logger.sh` 查看文件日志
2. **错误日志查看不方便** - 需要手动查找日志文件
3. **缺少实时监控** - 无法实时查看正在发生的操作

## 解决方案

### 1. 改进日志系统 (Logger.swift)

#### 三层日志输出
现在日志会同时输出到三个地方：

1. **标准输出 (print)** - Xcode 控制台可见
2. **系统日志 (os_log)** - Console.app 和 `log stream` 可见
3. **文件日志** - 持久化存储在 `~/.CloudDrive/Logs/`

#### 关键改进

```swift
// 1. 创建系统日志对象
private var osLogs: [String: OSLog] = [:]

// 2. 初始化时为每个类别创建 OSLog
osLogs[category.rawValue] = OSLog(subsystem: "net.aabg.CloudDrive", category: category.rawValue)

// 3. 记录日志时同时输出到三个地方
public func log(_ level: Level, category: Category, _ message: String, ...) {
    // 标准输出
    print("[\(category.rawValue.uppercased())] \(logMessage)")
    
    // 系统日志
    if let osLog = osLogs[category.rawValue] {
        os_log("%{public}@", log: osLog, type: level.osLogType, logMessage)
    }
    
    // 文件日志
    logQueue.async { [weak self] in
        self?.writeToFile(logMessage, category: category)
    }
}
```

### 2. 新增日志查看工具 (view_logs.sh)

创建了一个功能强大的交互式日志查看工具：

#### 主要功能

**📁 文件日志查看**
- 查看所有类别的日志
- 按类别查看（系统、文件操作、WebDAV、缓存、数据库）
- 自动着色（错误红色、警告黄色、成功绿色）

**🔴 实时监控**
- **选项 7: 实时监控 Xcode 运行日志** ⭐ 推荐
  - 使用 `log stream` 监控系统日志
  - 可以看到 Xcode 运行时的所有操作
  - 包括文件操作、错误、警告等
  
- **选项 8: 实时监控所有文件日志**
  - 监控所有日志文件的变化
  
- **选项 9: 实时监控文件操作日志**
  - 专门监控文件相关操作

**🔍 搜索和统计**
- 搜索所有错误日志
- 查看日志统计信息（文件数量、大小、各级别数量）
- 清理旧日志

## 使用方法

### 方法 1: 在 Xcode 中查看日志（推荐）

1. **在 Xcode 中运行应用**
   ```bash
   # 在 Xcode 中点击 Run 或按 Cmd+R
   ```

2. **查看 Xcode 控制台**
   - 打开 Xcode 底部的控制台面板
   - 所有日志会实时显示，包括：
     - `[SYSTEM]` - 系统日志
     - `[FILE-OPERATIONS]` - 文件操作日志 ⭐
     - `[WEBDAV]` - WebDAV 日志
     - `[CACHE]` - 缓存日志
     - `[DATABASE]` - 数据库日志

3. **过滤日志**
   - 在 Xcode 控制台搜索框输入关键词
   - 例如：`FILE-OPERATIONS` 只看文件操作
   - 例如：`ERROR` 只看错误

### 方法 2: 使用日志查看工具（推荐用于调试）

```bash
# 运行日志查看工具
./view_logs.sh
```

**最有用的选项：**

- **选项 7** - 实时监控 Xcode 运行日志
  ```bash
  # 在一个终端运行
  ./view_logs.sh
  # 选择 7
  
  # 在 Xcode 中运行应用
  # 终端会实时显示所有日志
  ```

- **选项 9** - 实时监控文件操作
  ```bash
  # 专门查看文件相关操作
  ./view_logs.sh
  # 选择 9
  ```

- **选项 10** - 搜索错误
  ```bash
  # 快速找到所有错误
  ./view_logs.sh
  # 选择 10
  ```

### 方法 3: 使用 macOS Console.app

1. 打开 Console.app（控制台应用）
2. 在搜索框输入：`subsystem:net.aabg.CloudDrive`
3. 可以看到所有系统日志
4. 支持实时监控和历史查看

### 方法 4: 使用命令行工具

```bash
# 实时监控系统日志
log stream --predicate 'subsystem == "net.aabg.CloudDrive"' --level debug

# 只看文件操作
log stream --predicate 'subsystem == "net.aabg.CloudDrive" AND category == "file-operations"' --level debug

# 只看错误
log stream --predicate 'subsystem == "net.aabg.CloudDrive"' --level error

# 查看文件日志
tail -f ~/.CloudDrive/Logs/file-operations-*.log

# 搜索错误
grep -r "ERROR" ~/.CloudDrive/Logs/
```

## 日志类别说明

### 1. 系统日志 (system)
- 应用启动/关闭
- 配置加载
- 保险库管理

### 2. 文件操作日志 (file-operations) ⭐ 重点
- 文件下载/上传
- 文件创建/删除/修改
- 文件移动/复制
- 目录操作
- FileProvider 扩展的所有操作

### 3. WebDAV 日志 (webdav)
- HTTP 请求/响应
- 连接状态
- 网络错误

### 4. 缓存日志 (cache)
- 缓存命中/未命中
- 文件缓存/清理

### 5. 数据库日志 (database)
- SQL 查询
- 数据库操作

## 日志级别

- 🔍 **DEBUG** - 详细调试信息
- ℹ️ **INFO** - 一般信息
- ⚠️ **WARNING** - 警告信息
- ❌ **ERROR** - 错误信息
- ✅ **SUCCESS** - 成功操作

## 调试示例

### 场景 1: 调试文件下载问题

**在 Xcode 中：**
1. 运行应用
2. 在控制台搜索 `FILE-OPERATIONS`
3. 执行文件操作
4. 实时查看日志输出

**使用日志工具：**
```bash
# 终端 1: 实时监控
./view_logs.sh
# 选择 7 (实时监控 Xcode 运行日志)

# 终端 2: 运行 Xcode 或执行操作
# 在终端 1 中会看到所有日志
```

### 场景 2: 查找错误原因

```bash
# 方法 1: 使用日志工具
./view_logs.sh
# 选择 10 (搜索错误日志)

# 方法 2: 命令行
grep -r "ERROR" ~/.CloudDrive/Logs/

# 方法 3: 系统日志
log show --predicate 'subsystem == "net.aabg.CloudDrive"' --level error --last 1h
```

### 场景 3: 追踪特定文件操作

```bash
# 实时监控文件操作
log stream --predicate 'subsystem == "net.aabg.CloudDrive" AND category == "file-operations"' --level debug

# 或使用日志工具
./view_logs.sh
# 选择 9
```

## 优势对比

### 之前的问题
❌ Xcode 运行时看不到文件操作日志  
❌ 必须用 `./test_logger.sh` 查看文件  
❌ 错误日志查看不方便  
❌ 无法实时监控  

### 现在的优势
✅ Xcode 控制台实时显示所有日志  
✅ 系统日志可用 Console.app 查看  
✅ 文件日志持久化保存  
✅ 多种实时监控方式  
✅ 强大的日志查看工具  
✅ 自动着色和分类  

## 性能影响

- 日志写入是异步的，不阻塞主线程
- 使用专用队列处理
- 系统日志性能优化
- 自动轮转和清理

## 下一步

1. **在 Xcode 中运行应用**
   ```bash
   # 在 Xcode 中按 Cmd+R
   ```

2. **查看控制台输出**
   - 应该能看到所有日志，包括文件操作

3. **测试文件操作**
   - 创建/删除文件
   - 查看 Xcode 控制台的实时日志

4. **使用日志工具**
   ```bash
   ./view_logs.sh
   # 选择 7 进行实时监控
   ```

## 故障排除

### 问题: Xcode 控制台看不到日志

**解决方案：**
1. 确保在 Xcode 中运行（不是直接打开 .app）
2. 检查 Xcode 控制台是否打开（View → Debug Area → Show Debug Area）
3. 清理并重新构建（Cmd+Shift+K，然后 Cmd+B）

### 问题: 日志工具选项 7 没有输出

**解决方案：**
1. 确保应用正在运行
2. 检查是否有权限访问系统日志
3. 尝试使用 `sudo` 运行：`sudo ./view_logs.sh`

### 问题: 文件日志目录不存在

**解决方案：**
```bash
# 手动创建目录
mkdir -p ~/.CloudDrive/Logs

# 或运行应用，会自动创建
```

## 总结

现在日志系统已经完全修复：
- ✅ Xcode 运行时可以实时看到所有日志
- ✅ 文件操作日志清晰可见
- ✅ 错误日志容易查找
- ✅ 多种查看方式可选
- ✅ 强大的实时监控功能

**推荐工作流程：**
1. 开发时在 Xcode 控制台查看日志
2. 调试时使用 `./view_logs.sh` 选项 7 实时监控
3. 排查问题时使用选项 10 搜索错误
4. 需要历史记录时查看文件日志