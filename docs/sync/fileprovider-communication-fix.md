# File Provider 通信问题修复指南

## 🔍 问题诊断结果

### 发现的问题

1. **✅ File Provider Extension 已安装**
   - Extension 正确安装在 `/Applications/CloudDrive.app/Contents/PlugIns/`
   
2. **❌ 保险库信息未保存到共享 UserDefaults**
   - 数据被保存到标准 UserDefaults (`net.aabg.CloudDrive`)
   - 应该保存到共享 UserDefaults (`group.net.aabg.CloudDrive`)
   - File Provider Extension 无法访问标准 UserDefaults

3. **❌ File Provider Domain 未注册**
   - 因为没有保险库信息，所以无法注册 Domain

4. **❌ File Provider 进程未运行**
   - 因为没有注册的 Domain，所以进程不会启动

## 🔧 已完成的修复

### 1. 修复 AppState.swift 中的 UserDefaults 初始化

**问题：** 如果共享 UserDefaults 初始化失败，会静默回退到标准 UserDefaults

**修复：** 添加日志输出，明确显示使用的是哪个 UserDefaults

```swift
// 修改前
private let userDefaults = UserDefaults(suiteName: "group.net.aabg.CloudDrive") ?? UserDefaults.standard

// 修改后
private let userDefaults: UserDefaults

init() {
    if let sharedDefaults = UserDefaults(suiteName: "group.net.aabg.CloudDrive") {
        self.userDefaults = sharedDefaults
        NSLog("✅ AppState: 使用共享 UserDefaults (App Group)")
    } else {
        NSLog("❌ AppState: 无法访问共享 UserDefaults，使用标准 UserDefaults")
        self.userDefaults = UserDefaults.standard
    }
}
```

### 2. 增强 File Provider Extension 日志

在所有文件操作中添加详细日志：
- 文件创建
- 文件修改
- 文件删除
- 目录创建

## 📋 修复步骤

### 步骤 1: 清理旧数据

```bash
# 删除标准 UserDefaults 中的旧数据
defaults delete net.aabg.CloudDrive savedVaults

# 清理 File Provider 缓存
rm -rf ~/Library/Group\ Containers/group.net.aabg.CloudDrive/.CloudDrive/*
```

### 步骤 2: 重新编译应用

```bash
cd /Users/snz/Desktop/CloudDrive

# 清理构建
xcodebuild clean

# 重新构建
xcodebuild build -scheme CloudDrive

# 或在 Xcode 中：
# Product -> Clean Build Folder (Shift+Cmd+K)
# Product -> Build (Cmd+B)
```

### 步骤 3: 重新安装应用

1. 从 Xcode 运行应用（会自动安装到 /Applications）
2. 或手动复制到 Applications 文件夹

### 步骤 4: 重新创建保险库

**重要：** 必须重新创建保险库，因为旧的保险库信息保存在错误的位置

1. 启动 CloudDrive 应用
2. 查看日志，确认看到：
   ```
   ✅ AppState: 使用共享 UserDefaults (App Group)
   ```
3. 创建新保险库
4. 解锁保险库

### 步骤 5: 验证修复

运行诊断脚本：
```bash
./diagnose_fileprovider.sh
```

**预期结果：**
```
1️⃣ File Provider Extension 安装状态
✅ 已安装

2️⃣ File Provider Domains
✅ 找到已注册的 Domain

3️⃣ 保存的保险库信息
✅ 找到保险库数据（在共享 UserDefaults 中）

4️⃣ File Provider 进程
✅ 进程正在运行

5️⃣ 文件系统挂载点
✅ 找到 CloudDrive 挂载点
```

### 步骤 6: 测试文件操作

```bash
# 启动日志监控
./test_sync.sh

# 在另一个终端测试文件写入
./test_file_write.sh
```

**预期日志输出：**
```
[File Provider Extension]
⬆️ FileProvider: Uploading file: test_xxx.txt
✅ FileProvider: Upload completed
📤 FileProvider: Notifying file change - vault: xxx, file: xxx
✅ FileProvider: File change notification sent

[主应用]
📢 AppState: 收到 File Provider 文件变化通知
   文件ID: xxx
   时间戳: xxx
```

## 🐛 如果仍然有问题

### 问题 A: 仍然使用标准 UserDefaults

**症状：** 日志显示 `❌ AppState: 无法访问共享 UserDefaults`

**解决方案：**
1. 检查 `CloudDrive/CloudDrive.entitlements`：
   ```bash
   cat CloudDrive/CloudDrive.entitlements | grep -A 3 "application-groups"
   ```
   应该包含：
   ```xml
   <key>com.apple.security.application-groups</key>
   <array>
       <string>group.net.aabg.CloudDrive</string>
   </array>
   ```

2. 重新签名应用：
   ```bash
   codesign --force --deep --sign - /Applications/CloudDrive.app
   ```

### 问题 B: File Provider Extension 无法获取保险库信息

**症状：** 日志显示 `⚠️ FileProvider: No vault info available`

**解决方案：**
1. 确认共享 UserDefaults 中有数据：
   ```bash
   defaults read group.net.aabg.CloudDrive savedVaults
   ```

2. 检查 File Provider Extension 的 entitlements：
   ```bash
   codesign -d --entitlements :- /Applications/CloudDrive.app/Contents/PlugIns/CloudDriveFileProvider.appex | grep -A 3 "application-groups"
   ```

### 问题 C: File Provider 进程不启动

**症状：** `ps aux | grep CloudDriveFileProvider` 没有结果

**解决方案：**
1. 重新注册 File Provider Extension：
   ```bash
   pluginkit -a /Applications/CloudDrive.app/Contents/PlugIns/CloudDriveFileProvider.appex
   pluginkit -e use -i net.aabg.CloudDrive.CloudDriveFileProvider
   ```

2. 在 Finder 中访问保险库来触发启动

3. 查看系统日志：
   ```bash
   log stream --predicate 'processImagePath CONTAINS "CloudDriveFileProvider"' --level debug
   ```

## ✅ 成功标准

修复成功的标志：

1. ✅ 应用启动时日志显示使用共享 UserDefaults
2. ✅ 创建保险库后，诊断脚本显示所有检查通过
3. ✅ 在 Finder 中可以看到保险库
4. ✅ 在保险库中创建文件时，主应用收到通知
5. ✅ 所有文件操作（创建、修改、删除）都有完整的日志

## 📚 相关文件

- `CloudDrive/AppState.swift` - 主应用状态管理
- `CloudDriveFileProvider/FileProviderExtension.swift` - File Provider 实现
- `CloudDriveCore/FileProviderSync.swift` - 跨进程通信
- `diagnose_fileprovider.sh` - 诊断工具
- `test_sync.sh` - 日志监控工具
- `test_file_write.sh` - 文件写入测试工具