#!/bin/bash

# 修复 Bridging Header 问题的脚本

PROJECT_DIR="/Users/snz/Desktop/CloudDrive/CloudDrive"
PBXPROJ="$PROJECT_DIR/CloudDrive.xcodeproj/project.pbxproj"

echo "🔧 修复 Bridging Header 配置..."

# 备份项目文件
cp "$PBXPROJ" "$PBXPROJ.backup"

# 删除 Bridging Header 相关的配置
sed -i '' '/SWIFT_OBJC_BRIDGING_HEADER/d' "$PBXPROJ"

echo "✅ 已删除 Bridging Header 配置"
echo "📝 原文件已备份到: $PBXPROJ.backup"
echo ""
echo "现在可以在 Xcode 中重新编译项目了！"