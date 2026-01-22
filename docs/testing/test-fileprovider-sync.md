# File Provider 通信测试指南

## ✅ 已确认工作的功能

根据日志输出，以下功能已经正常工作：

1. **保险库解锁通知** ✅
   - 主应用发送：`📤 FileProviderSync: 发送保险库解锁通知`
   - File Provider 接收：`📢 FileProviderSync: 收到保险库解锁通知`

## 🔍 需要测试的功能

### 1. 文件创建通知

**预期日志流程：**
```
[File Provider Extension]
⬆️ FileProvider: Uploading file: test.txt
📤 FileProvider: Notifying file change - vault: xxx, file: xxx
✅ FileProvider: File change notification sent

[主应用]
📢 AppState: 收到 File Provider 文件变化通知
   文件ID: xxx
   时间戳: xxx
```

### 2. 目录创建通知

**预期日志流程：**
```
[File Provider Extension]
📁 FileProvider: Creating directory: NewFolder
📤 FileProvider: Notifying directory creation - vault: xxx, dir: xxx
✅ FileProvider: Directory creation notification sent

[主应用]
📢 AppState: 收到 File Provider 文件变化通知
```

### 3. 文件修改通知

**预期日志流程：**
```
[File Provider Extension]
🔄 FileProvider: Modifying file: test.txt
📤 FileProvider: Notifying file modification - vault: xxx, file: xxx
✅ FileProvider: File modification notification sent

[主应用]
📢 AppState: 收到 File Provider 文件变化通知
```

### 4. 文件删除通知

**预期日志流程：**
```
[File Provider Extension]
🗑️ FileProvider: Deleting item: xxx
📤 FileProvider: Notifying file deletion - vault: xxx, file: xxx
✅ FileProvider: File deletion notification sent

[主应用]
📢 AppState: 收到 File Provider 文件变化通知
```

## 🧪 测试步骤

### 准备工作

1. **重新编译项目**
   ```bash
   cd /Users/snz/Desktop/CloudDrive
   xcodebuild clean
   xcodebuild build
   ```

2. **启动日志监控**
   ```bash
   ./test_sync.sh
   ```
   保持这个终端窗口打开，它会实时显示所有日志。

3. **运行应用**
   - 在 Xcode 中运行 CloudDrive
   - 或者直接从 Applications 文件夹启动

### 测试 1: 文件创建

1. 在 Finder 中打开已挂载的保险库
2. 创建一个新文本文件：
   ```bash
   ./test_file_write.sh
   ```
   或者手动在 Finder 中创建文件

3. **检查日志输出**，应该看到：
   - ✅ File Provider 发送通知
   - ✅ 主应用接收通知

### 测试 2: 目录创建

1. 在 Finder 的保险库中创建新文件夹
2. 检查日志输出

### 测试 3: 文件修改

1. 编辑保险库中的现有文件
2. 保存文件
3. 检查日志输出

### 测试 4: 文件删除

1. 删除保险库中的文件
2. 检查日志输出

## 🐛 可能的问题和解决方案

### 问题 1: 看不到 File Provider 的日志

**原因：** File Provider Extension 是独立进程，日志可能被过滤

**解决方案：**
```bash
# 使用 Console.app 查看
open /System/Applications/Utilities/Console.app

# 或使用命令行
log stream --predicate 'processImagePath CONTAINS "CloudDriveFileProvider"' --level debug
```

### 问题 2: 主应用没有收到通知

**可能原因：**
1. `vaultInfo` 为 nil（File Provider 没有保险库信息）
2. Darwin 通知名称不匹配
3. 通知监听器未正确设置

**检查方法：**
查看日志中是否有：
- `⚠️ FileProvider: No vault info available, cannot send notification`
- 如果有，说明 File Provider 没有正确获取保险库信息

### 问题 3: 通知发送了但主应用没反应

**可能原因：**
1. 主应用的通知监听器未启动
2. App Group 配置不正确

**检查方法：**
1. 确认主应用启动时看到：
   ```
   ✅ AppState: FileProviderSync 已初始化
   ✅ AppState: 通知监听器已设置
   ```

2. 检查 entitlements 文件中的 App Group：
   ```bash
   cat CloudDrive/CloudDrive.entitlements
   cat CloudDriveFileProvider/CloudDriveFileProvider.entitlements
   ```
   两者应该都包含 `group.net.aabg.CloudDrive`

## 📊 成功标准

所有测试通过的标志：

- ✅ 文件创建时，主应用收到通知
- ✅ 目录创建时，主应用收到通知
- ✅ 文件修改时，主应用收到通知
- ✅ 文件删除时，主应用收到通知
- ✅ 所有操作的日志都完整显示

## 🎯 下一步

如果所有测试通过：
1. 可以开始实现主应用对文件变化的响应（如更新 UI）
2. 可以添加更复杂的同步逻辑
3. 可以实现冲突解决机制

如果测试失败：
1. 查看具体的错误日志
2. 根据上面的"可能的问题和解决方案"进行排查
3. 如需帮助，提供完整的日志输出