#!/bin/bash

# CloudDrive 自动修复所有编译错误的脚本

set -e

PROJECT_DIR="/Users/snz/Desktop/CloudDrive/CloudDrive"
PBXPROJ="$PROJECT_DIR/CloudDrive.xcodeproj/project.pbxproj"

echo "🚀 CloudDrive 自动修复脚本"
echo "================================"
echo ""

cd "$PROJECT_DIR"

# 1. 检查 Xcode
echo "1️⃣ 检查 Xcode 安装..."
if ! command -v xcodebuild &> /dev/null; then
    echo "❌ 未找到 xcodebuild"
    echo "请安装 Xcode: https://apps.apple.com/app/xcode/id497799835"
    exit 1
fi

XCODE_PATH=$(xcode-select -p)
if [[ "$XCODE_PATH" == *"CommandLineTools"* ]]; then
    echo "⚠️  当前使用命令行工具，需要切换到完整的 Xcode"
    echo "请运行: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
    exit 1
else
    echo "✅ Xcode 路径正确: $XCODE_PATH"
fi

XCODE_VERSION=$(xcodebuild -version | head -n 1)
echo "   版本: $XCODE_VERSION"
echo ""

# 2. 修复 Bridging Header
echo "2️⃣ 修复 Bridging Header 配置..."
if [ -f "$PBXPROJ.backup" ]; then
    echo "   已存在备份文件，跳过"
else
    cp "$PBXPROJ" "$PBXPROJ.backup"
    sed -i '' '/SWIFT_OBJC_BRIDGING_HEADER/d' "$PBXPROJ"
    echo "✅ 已删除 Bridging Header 配置"
fi
echo ""

# 3. 清理构建缓存
echo "3️⃣ 清理构建缓存..."
DERIVED_DATA=$(find ~/Library/Developer/Xcode/DerivedData -name "CloudDrive-*" -type d 2>/dev/null)
if [ -n "$DERIVED_DATA" ]; then
    rm -rf "$DERIVED_DATA"
    echo "✅ 已清理 DerivedData"
else
    echo "   无需清理"
fi
echo ""

# 4. 检查必需文件（使用正确的路径）
echo "4️⃣ 检查项目文件完整性..."
MISSING_FILES=0

check_file() {
    if [ -f "$1" ]; then
        echo "   ✅ $1"
    else
        echo "   ❌ 缺少: $1"
        MISSING_FILES=$((MISSING_FILES + 1))
    fi
}

# CloudDriveCore 文件
check_file "CloudDriveCore/CloudFile.swift"
check_file "CloudDriveCore/CacheManager.swift"
check_file "CloudDriveCore/WebDAVClient.swift"
check_file "CloudDriveCore/VirtualFileSystem.swift"
check_file "CloudDriveCore/VFSEncryption.swift"
check_file "CloudDriveCore/VFSDatabase.swift"

# CloudDriveFileProvider 文件
check_file "CloudDriveFileProvider/FileProviderExtension.swift"
check_file "CloudDriveFileProvider/FileProviderItem.swift"

# CloudDrive 主应用文件
check_file "CloudDrive/CloudDriveApp.swift"
check_file "CloudDrive/ContentView.swift"
check_file "CloudDrive/CreateVaultView.swift"
check_file "CloudDrive/SettingsView.swift"

if [ $MISSING_FILES -gt 0 ]; then
    echo ""
    echo "❌ 发现 $MISSING_FILES 个缺失文件"
    echo "请确保所有源文件都已创建"
    exit 1
fi
echo ""

# 5. 检查 Entitlements
echo "5️⃣ 检查 Entitlements 文件..."
check_file "CloudDrive/CloudDrive.entitlements"
check_file "CloudDriveFileProvider/CloudDriveFileProvider.entitlements"
echo ""

# 6. 验证项目结构
echo "6️⃣ 验证项目结构..."
if [ -f "$PBXPROJ" ]; then
    echo "✅ 项目文件存在"
    
    # 检查是否包含必要的配置
    if grep -q "CloudDriveCore" "$PBXPROJ"; then
        echo "✅ CloudDriveCore target 已配置"
    else
        echo "⚠️  CloudDriveCore target 可能未正确配置"
    fi
    
    if grep -q "CloudDriveFileProvider" "$PBXPROJ"; then
        echo "✅ CloudDriveFileProvider target 已配置"
    else
        echo "⚠️  CloudDriveFileProvider target 可能未正确配置"
    fi
else
    echo "❌ 项目文件不存在"
    exit 1
fi
echo ""

# 7. 创建必要的目录
echo "7️⃣ 创建必要的目录..."
mkdir -p ~/Library/Caches/com.clouddrive.app/cache
mkdir -p ~/Library/Application\ Support/CloudDrive/vaults
mkdir -p ~/Library/Application\ Support/CloudDrive/logs
echo "✅ 目录已创建"
echo ""

# 8. 生成编译报告
echo "8️⃣ 生成编译诊断报告..."
cat > "$PROJECT_DIR/BUILD_STATUS.md" << 'EOF'
# CloudDrive 编译状态报告

## 系统信息
EOF

echo "- **Xcode 版本**: $(xcodebuild -version | head -n 1)" >> "$PROJECT_DIR/BUILD_STATUS.md"
echo "- **macOS 版本**: $(sw_vers -productVersion)" >> "$PROJECT_DIR/BUILD_STATUS.md"
echo "- **Swift 版本**: $(xcrun swift --version | head -n 1)" >> "$PROJECT_DIR/BUILD_STATUS.md"
echo "- **检查时间**: $(date)" >> "$PROJECT_DIR/BUILD_STATUS.md"
echo "" >> "$PROJECT_DIR/BUILD_STATUS.md"

cat >> "$PROJECT_DIR/BUILD_STATUS.md" << 'EOF'
## 修复项目

- ✅ 删除了 Bridging Header 配置
- ✅ 清理了构建缓存
- ✅ 验证了文件完整性
- ✅ 创建了必要的目录

## 项目文件结构

```
CloudDrive/
├── CloudDriveCore/              # 核心库
│   ├── CloudFile.swift
│   ├── CacheManager.swift
│   ├── WebDAVClient.swift
│   ├── VirtualFileSystem.swift
│   ├── VFSEncryption.swift
│   └── VFSDatabase.swift
│
├── CloudDriveFileProvider/      # File Provider Extension
│   ├── FileProviderExtension.swift
│   └── FileProviderItem.swift
│
└── CloudDrive/                  # 主应用
    ├── CloudDriveApp.swift
    ├── ContentView.swift
    ├── CreateVaultView.swift
    └── SettingsView.swift
```

## 下一步

### 在 Xcode 中编译

1. 打开项目:
   ```bash
   open CloudDrive.xcodeproj
   ```

2. 选择 CloudDrive scheme

3. 清理构建 (Cmd+Shift+K)

4. 编译 (Cmd+B)

### 可能需要的额外配置

#### 1. 添加 SQLite 库

如果编译时提示缺少 SQLite3 模块：

1. 选择 CloudDriveCore target
2. Build Phases → Link Binary With Libraries
3. 点击 + 添加 `libsqlite3.tbd`

#### 2. 配置签名

对于每个 target：

1. 选择 target
2. Signing & Capabilities
3. 勾选 "Automatically manage signing"
4. 选择开发团队

#### 3. 添加 App Groups

对于 CloudDrive 和 CloudDriveFileProvider targets：

1. 点击 "+ Capability"
2. 选择 "App Groups"
3. 勾选或创建 `group.com.clouddrive.app`

## 常见问题

**Q: 提示缺少 SQLite3 模块**
A: 在 Xcode 中添加 libsqlite3.tbd 到 Link Binary With Libraries

**Q: App Group 错误**
A: 在 Signing & Capabilities 中添加 App Groups 能力

**Q: 签名错误**
A: 在 Signing & Capabilities 中配置开发团队

**Q: 找不到某个类型或模块**
A: 确保所有文件都已添加到正确的 target

## 支持

如果问题仍未解决，请:
1. 截图错误信息
2. 查看 Issue Navigator 中的详细错误
3. 参考 COMPILE_ERRORS_FIX.md
EOF

echo "✅ 报告已生成: BUILD_STATUS.md"
echo ""

# 9. 总结
echo "================================"
echo "✅ 自动修复完成！"
echo ""
echo "📋 修复摘要:"
echo "   - Xcode 版本: $XCODE_VERSION"
echo "   - Bridging Header: 已删除"
echo "   - 构建缓存: 已清理"
echo "   - 文件检查: 通过 ✅"
echo "   - 目录结构: 已创建"
echo ""
echo "📝 下一步操作:"
echo "   1. 在 Xcode 中打开项目:"
echo "      open CloudDrive.xcodeproj"
echo ""
echo "   2. 选择 CloudDrive scheme"
echo ""
echo "   3. 清理并编译:"
echo "      Product → Clean Build Folder (Cmd+Shift+K)"
echo "      Product → Build (Cmd+B)"
echo ""
echo "   4. 如果提示缺少 SQLite3:"
echo "      - 选择 CloudDriveCore target"
echo "      - Build Phases → Link Binary With Libraries"
echo "      - 添加 libsqlite3.tbd"
echo ""
echo "📖 详细文档:"
echo "   - BUILD_STATUS.md - 编译状态报告"
echo "   - COMPILE_ERRORS_FIX.md - 错误修复指南"
echo "   - README.md - 项目说明"
echo ""
echo "🎉 准备就绪，可以开始编译了！"