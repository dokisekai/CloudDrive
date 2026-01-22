# 快速设置指南

✅ 所有代码文件已复制完成！

## 📂 已复制的文件

### CloudDriveCore (6 个文件)
- ✅ CloudFile.swift
- ✅ CacheManager.swift
- ✅ WebDAVClient.swift
- ✅ VirtualFileSystem.swift
- ✅ VFSEncryption.swift
- ✅ VFSDatabase.swift

### CloudDriveFileProvider (2 个文件)
- ✅ FileProviderExtension.swift
- ✅ FileProviderItem.swift

### CloudDrive (4 个文件)
- ✅ CloudDriveApp.swift
- ✅ ContentView.swift
- ✅ CreateVaultView.swift
- ✅ SettingsView.swift

## 🎯 下一步：在 Xcode 中配置

### 步骤 1：打开项目

```bash
open /Users/snz/Desktop/CloudDrive/CloudDrive/CloudDrive.xcodeproj
```

### 步骤 2：添加文件到 Xcode

对于每个 target，需要将文件添加到 Xcode 项目中：

#### CloudDriveCore
1. 在 Xcode 左侧找到 `CloudDriveCore` 文件夹
2. 右键点击 → `Add Files to "CloudDrive"`
3. 选择以下文件（按住 Cmd 多选）：
   - CloudFile.swift
   - CacheManager.swift
   - WebDAVClient.swift
   - VirtualFileSystem.swift
   - VFSEncryption.swift
   - VFSDatabase.swift
4. 确保 `Target Membership` 只选中 `CloudDriveCore`

#### CloudDriveFileProvider
1. 找到 `CloudDriveFileProvider` 文件夹
2. 右键 → `Add Files to "CloudDrive"`
3. 选择：
   - FileProviderExtension.swift
   - FileProviderItem.swift
4. Target 选择 `CloudDriveFileProvider`

#### CloudDrive
1. 找到 `CloudDrive` 文件夹
2. 右键 → `Add Files to "CloudDrive"`
3. 选择：
   - CloudDriveApp.swift
   - ContentView.swift
   - CreateVaultView.swift
   - SettingsView.swift
4. Target 选择 `CloudDrive`

### 步骤 3：配置 App Group

#### 为 CloudDrive target：
1. 选择项目 → `CloudDrive` target
2. `Signing & Capabilities` 标签
3. 点击 `+ Capability`
4. 选择 `App Groups`
5. 点击 `+` 添加：`group.com.clouddrive.shared`

#### 为 CloudDriveFileProvider target：
重复以上步骤，添加相同的 App Group

### 步骤 4：配置 Framework 依赖

#### CloudDrive 依赖 CloudDriveCore：
1. 选择 `CloudDrive` target
2. `General` 标签
3. `Frameworks, Libraries, and Embedded Content` 部分
4. 点击 `+`
5. 选择 `CloudDriveCore.framework`
6. 设置为 `Embed & Sign`

#### CloudDriveFileProvider 依赖 CloudDriveCore：
1. 选择 `CloudDriveFileProvider` target
2. 重复以上步骤

### 步骤 5：配置 Build Settings

#### CloudDriveCore：
1. 选择 `CloudDriveCore` target
2. `Build Settings` 标签
3. 搜索 "Defines Module"
4. 设置为 `Yes`

### 步骤 6：构建项目

按 `Cmd + B` 构建项目

如果遇到错误，查看下面的常见问题。

## 🐛 常见问题

### 错误 1：找不到 CommonCrypto

**解决方法**：
1. 选择 `CloudDriveCore` target
2. `Build Settings` → 搜索 "Swift Compiler - Search Paths"
3. 在 "Import Paths" 添加：`$(SDKROOT)/usr/include/CommonCrypto`

或者创建 Bridging Header：
```bash
# 在 CloudDriveCore 目录创建
cat > /Users/snz/Desktop/CloudDrive/CloudDrive/CloudDriveCore/CloudDriveCore-Bridging-Header.h << 'EOF'
#import <CommonCrypto/CommonCrypto.h>
EOF
```

然后在 Build Settings 中设置 Bridging Header 路径。

### 错误 2：找不到 SQLite3

SQLite3 是系统库，应该自动链接。如果有问题：
1. 选择 `CloudDriveCore` target
2. `Build Phases` → `Link Binary With Libraries`
3. 点击 `+` → 添加 `libsqlite3.tbd`

### 错误 3：App Group 错误

确保：
1. 所有 targets 使用相同的 App Group ID
2. Bundle Identifier 正确
3. 开发团队已选择

## 🚀 运行应用

1. 选择 scheme: `CloudDrive > My Mac`
2. 按 `Cmd + R` 运行
3. 应用会启动并显示欢迎界面

## 🧪 测试 WebDAV

启动本地 WebDAV 服务器：

```bash
# 安装 wsgidav
pip3 install wsgidav cheroot

# 创建存储目录
mkdir -p ~/webdav-storage

# 启动服务器
wsgidav --host=0.0.0.0 --port=8080 --root=~/webdav-storage --auth=anonymous
```

在应用中使用：
- WebDAV URL: `http://localhost:8080`
- 用户名: （留空）
- 密码: （留空）

## 📝 使用流程

1. 运行应用
2. 点击"创建新保险库"
3. 输入保险库名称和密码
4. 配置 WebDAV 连接
5. 点击创建
6. 打开 Finder，在侧边栏找到 "CloudDrive"
7. 拖放文件测试

## 🎉 完成！

现在你有一个完整的加密云盘系统，就像 iCloud Drive 一样使用！

所有文件都会自动加密后上传到 WebDAV 服务器。