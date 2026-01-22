# 查看 CloudDrive 日志的方法

## 方法 1：使用 Console.app（推荐）

### 步骤：
1. 打开 **Console.app**（在 `/Applications/Utilities/Console.app`）
2. 在左侧选择你的 Mac
3. 在搜索框输入：`CloudDrive` 或 `process:CloudDrive`
4. 点击 "开始" 按钮开始捕获日志
5. 运行你的应用
6. 所有 `print()` 输出都会显示在这里

### 过滤器：
```
subsystem:com.clouddrive
process:CloudDrive
category:VFS
```

## 方法 2：使用终端命令

### 实时查看日志：
```bash
# 查看所有 CloudDrive 相关日志
log stream --predicate 'process == "CloudDrive"' --level debug

# 或者更简单的方式
log stream --process CloudDrive

# 查看最近的日志
log show --predicate 'process == "CloudDrive"' --last 5m
```

### 保存日志到文件：
```bash
log stream --process CloudDrive > ~/Desktop/clouddrive.log
```

## 方法 3：使用 Xcode 运行（最佳调试方式）

### 步骤：
1. 在 Xcode 中打开项目
2. 选择 **CloudDrive** scheme
3. 点击 **Run** 按钮（或按 Cmd+R）
4. 日志会显示在 Xcode 底部的 **Console** 区域

### 如果看不到 Console：
- 按 `Cmd+Shift+Y` 显示调试区域
- 或者点击 Xcode 右上角的调试区域按钮

## 方法 4：从命令行启动并查看日志

创建一个启动脚本：

```bash
#!/bin/bash
# 文件名：run_with_logs.sh

APP_PATH="/Users/snz/Library/Developer/Xcode/DerivedData/CloudDrive-bsjqbgoyvvpkcjguocaafjnxjvaj/Build/Products/Debug/CloudDrive.app"

echo "🚀 启动 CloudDrive..."
echo "📋 日志将显示在下方"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 在后台启动应用
open "$APP_PATH"

# 等待应用启动
sleep 2

# 实时显示日志
log stream --process CloudDrive --level debug
```

### 使用方法：
```bash
chmod +x run_with_logs.sh
./run_with_logs.sh
```

## 方法 5：添加日志文件输出

在代码中添加日志文件输出（已为你准备好）：

### 使用 Logger 类：
```swift
import os.log

class AppLogger {
    static let shared = AppLogger()
    private let logger = Logger(subsystem: "com.clouddrive", category: "app")
    private let fileURL: URL
    
    init() {
        let logDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = logDir.appendingPathComponent("clouddrive.log")
    }
    
    func log(_ message: String) {
        logger.info("\(message)")
        
        // 同时写入文件
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logMessage = "[\(timestamp)] \(message)\n"
        
        if let data = logMessage.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if let fileHandle = try? FileHandle(forWritingTo: fileURL) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
```

## 当前日志位置

根据代码，日志会输出到：

1. **数据库日志**：
   - App Group: `/Users/snz/Library/Group Containers/group.com.clouddrive.shared/vfs.db`
   - 或应用支持目录: `~/Library/Application Support/CloudDrive/vfs.db`

2. **保险库列表**：
   - `~/Library/Application Support/CloudDrive/vaults.json`

3. **书签文件**：
   - `~/Library/Application Support/CloudDrive/[vaultId].bookmark`

## 快速调试命令

```bash
# 查看应用支持目录
open ~/Library/Application\ Support/CloudDrive/

# 查看 App Group 目录
open ~/Library/Group\ Containers/group.com.clouddrive.shared/

# 查看最近的崩溃日志
open ~/Library/Logs/DiagnosticReports/

# 清理所有数据重新开始
rm -rf ~/Library/Application\ Support/CloudDrive/
rm -rf ~/Library/Group\ Containers/group.com.clouddrive.shared/
```

## 推荐的调试流程

1. **首次调试**：使用 Xcode 运行（Cmd+R）
2. **查看实时日志**：使用 Console.app
3. **分析问题**：使用 `log show` 命令查看历史日志
4. **持续监控**：使用 `log stream` 保存到文件

## 常见问题

### Q: 看不到任何日志？
A: 确保应用有正确的权限，检查沙箱设置

### Q: 日志太多？
A: 使用过滤器：`log stream --process CloudDrive --predicate 'eventMessage contains "VFS"'`

### Q: 需要更详细的日志？
A: 在代码中使用 `os.log` 替代 `print()`