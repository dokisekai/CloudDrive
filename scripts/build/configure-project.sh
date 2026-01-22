#!/bin/bash

# CloudDrive 项目自动配置脚本

echo "🚀 开始配置 CloudDrive 项目..."

PROJECT_DIR="/Users/snz/Desktop/CloudDrive/CloudDrive"
PBXPROJ="$PROJECT_DIR/CloudDrive.xcodeproj/project.pbxproj"

# 备份原始项目文件
echo "📦 备份项目文件..."
cp "$PBXPROJ" "$PBXPROJ.backup"

# 打开 Xcode 项目
echo "📂 打开 Xcode 项目..."
open "$PROJECT_DIR/CloudDrive.xcodeproj"

echo ""
echo "✅ 配置文件已更新："
echo "   ✓ CloudDrive.entitlements - 已添加 App Group"
echo "   ✓ CloudDriveFileProvider.entitlements - 已添加 App Group"
echo "   ✓ CloudDriveCore-Bridging-Header.h - 已创建"
echo ""
echo "⚠️  请在 Xcode 中完成以下步骤："
echo ""
echo "1️⃣  配置 CloudDriveCore Bridging Header："
echo "   - 选择 CloudDriveCore target"
echo "   - Build Settings → 搜索 'Bridging Header'"
echo "   - 设置为: CloudDriveCore/CloudDriveCore-Bridging-Header.h"
echo ""
echo "2️⃣  添加 Framework 依赖："
echo "   - 选择 CloudDrive target → General"
echo "   - Frameworks, Libraries, and Embedded Content"
echo "   - 点击 + → 选择 CloudDriveCore.framework → Embed & Sign"
echo ""
echo "   - 选择 CloudDriveFileProvider target"
echo "   - 重复上述步骤添加 CloudDriveCore.framework"
echo ""
echo "3️⃣  构建项目："
echo "   - 按 Cmd + B 构建"
echo "   - 按 Cmd + R 运行"
echo ""
echo "🎉 配置完成！"