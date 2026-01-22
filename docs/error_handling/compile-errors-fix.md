# macOS 编译错误修复指南

## 前提条件检查

### 1. 确认 Xcode 安装
```bash
# 检查 Xcode 是否安装
xcode-select -p

# 如果显示 /Library/Developer/CommandLineTools，需要切换到 Xcode
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer

# 验证
xcodebuild -version
```

## 常见编译错误及解决方案

### 错误 1: Bridging Header 不支持
```
error: Using bridging headers with framework targets is unsupported
```

**已修复**: 运行 `./fix_bridging_header.sh`

---

### 错误 2: 缺少 SQLite3 库
```
error: No such module 'SQLite3'
```

**解决方案**:
1. 在 Xcode 中打开项目
2. 选择 CloudDriveCore target
3. Build Phases → Link Binary With Libraries
4. 点击 + 添加 `libsqlite3.tbd`

或运行脚本:
```bash
./add_sqlite_framework.sh
```

---

### 错误 3: App Group 未配置
```
error: Provisioning profile doesn't include the application-groups entitlement
```

**解决方案**:
1. 在 Xcode 中选择项目
2. 选择每个 target
3. Signing & Capabilities
4. 点击 + Capability
5. 添加 App Groups
6. 勾选 `group.com.clouddrive.app`

---

### 错误 4: 缺少 VFSError 定义
```
error: Cannot find 'VFSError' in scope
```

**解决方案**: 需要在 VirtualFileSystem.swift 中定义错误类型

---

### 错误 5: FileProvider 相关错误
```
error: Cannot find type 'NSFileProviderItemIdentifier' in scope
```

**解决方案**: 确保导入了 FileProvider 框架
```swift
import FileProvider
```

---

## 完整修复脚本

创建并运行以下脚本来自动修复所有问题:

```bash
#!/bin/bash

echo "🔧 开始修复 CloudDrive 编译错误..."

PROJECT_DIR="/Users/snz/Desktop/CloudDrive/CloudDrive"
cd "$PROJECT_DIR"

# 1. 修复 Xcode 路径
echo "1️⃣ 检查 Xcode 路径..."
if [[ $(xcode-select -p) == *"CommandLineTools"* ]]; then
    echo "⚠️  需要切换到完整的 Xcode"
    echo "请运行: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
fi

# 2. 修复 Bridging Header
echo "2️⃣ 修复 Bridging Header..."
./fix_bridging_header.sh

# 3. 清理构建
echo "3️⃣ 清理构建缓存..."
rm -rf ~/Library/Developer/Xcode/DerivedData/CloudDrive-*

# 4. 检查文件完整性
echo "4️⃣ 检查文件完整性..."
required_files=(
    "CloudDriveCore/Models/CloudFile.swift"
    "CloudDriveCore/CacheManager/CacheManager.swift"
    "CloudDriveCore/WebDAV/WebDAVClient.swift"
    "CloudDriveCore/VirtualFileSystem/VirtualFileSystem.swift"
    "CloudDriveCore/VirtualFileSystem/VFSEncryption.swift"
    "CloudDriveCore/VirtualFileSystem/VFSDatabase.swift"
)

for file in "${required_files[@]}"; do
    if [ ! -f "$file" ]; then
        echo "❌ 缺少文件: $file"
    else
        echo "✅ $file"
    fi
done

echo ""
echo "✅ 修复完成！"
echo ""
echo "📝 下一步:"
echo "1. 在 Xcode 中打开项目"
echo "2. 选择 CloudDrive scheme"
echo "3. Product → Clean Build Folder (Cmd+Shift+K)"
echo "4. Product → Build (Cmd+B)"
echo ""
echo "如果仍有错误，请查看具体错误信息并参考本文档。"
```

---

## 手动编译步骤

### 在 Xcode 中编译

1. **打开项目**
   ```bash
   open /Users/snz/Desktop/CloudDrive/CloudDrive/CloudDrive.xcodeproj
   ```

2. **选择 Scheme**
   - 点击顶部工具栏的 scheme 选择器
   - 选择 "CloudDrive"
   - 选择目标设备（My Mac）

3. **清理构建**
   - 菜单: Product → Clean Build Folder
   - 或按 Cmd+Shift+K

4. **编译**
   - 菜单: Product → Build
   - 或按 Cmd+B

5. **查看错误**
   - 如果有错误，会在 Issue Navigator 中显示
   - 点击错误查看详细信息

---

## 逐个 Target 编译

### 1. 先编译 CloudDriveCore
```bash
# 在 Xcode 中
1. 选择 CloudDriveCore scheme
2. Cmd+B 编译
3. 查看并修复错误
```

### 2. 再编译 CloudDriveFileProvider
```bash
1. 选择 CloudDriveFileProvider scheme
2. Cmd+B 编译
3. 查看并修复错误
```

### 3. 最后编译主应用
```bash
1. 选择 CloudDrive scheme
2. Cmd+B 编译
```

---

## 需要添加的代码修复

### 修复 1: 添加 VFSError 定义

在 `VirtualFileSystem.swift` 开头添加:

```swift
enum VFSError: Error {
    case encryptionFailed
    case decryptionFailed
    case databaseError
    case fileNotFound
    case invalidPath
    case networkError
    case authenticationFailed
}
```

### 修复 2: 添加缺少的导入

在每个文件顶部确保有正确的导入:

```swift
// CloudFile.swift
import Foundation

// CacheManager.swift
import Foundation

// WebDAVClient.swift
import Foundation

// VirtualFileSystem.swift
import Foundation
import CryptoKit

// VFSEncryption.swift
import Foundation
import CryptoKit

// VFSDatabase.swift
import Foundation
import SQLite3

// FileProviderExtension.swift
import FileProvider
import UniformTypeIdentifiers

// FileProviderItem.swift
import FileProvider
import UniformTypeIdentifiers
```

---

## 检查清单

编译前请确认:

- [ ] Xcode 已安装（不是命令行工具）
- [ ] Xcode 版本 15.0+
- [ ] macOS 版本 14.0+
- [ ] 已运行 `fix_bridging_header.sh`
- [ ] 已清理构建缓存
- [ ] 所有必需文件都存在
- [ ] App Group 已配置
- [ ] 签名证书已设置

---

## 获取详细错误信息

如果编译失败，请提供以下信息:

1. **Xcode 版本**
   ```bash
   xcodebuild -version
   ```

2. **macOS 版本**
   ```bash
   sw_vers
   ```

3. **完整错误日志**
   - 在 Xcode 中: View → Navigators → Show Report Navigator
   - 选择最新的构建
   - 复制完整错误信息

4. **具体错误文件和行号**

---

## 联系支持

如果按照以上步骤仍无法解决，请:

1. 截图错误信息
2. 提供 Xcode 版本和 macOS 版本
3. 说明已尝试的修复步骤
4. 创建 Issue 并附上以上信息

---

**最后更新**: 2025-12-17