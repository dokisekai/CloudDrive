#!/bin/bash

echo "🧹 清理 Xcode 构建缓存..."

# 清理 DerivedData
echo "1️⃣ 清理 DerivedData..."
rm -rf ~/Library/Developer/Xcode/DerivedData/CloudDrive-*

# 清理项目构建文件
echo "2️⃣ 清理项目构建文件..."
cd "$(dirname "$0")"
rm -rf build/
rm -rf .build/

# 清理 Xcode 缓存
echo "3️⃣ 清理 Xcode 模块缓存..."
rm -rf ~/Library/Caches/com.apple.dt.Xcode/

echo ""
echo "✅ 清理完成！"
echo ""
echo "📝 下一步："
echo "1. 在 Xcode 中打开项目"
echo "2. 按 Cmd+Shift+K (Product > Clean Build Folder)"
echo "3. 按 Cmd+B (Product > Build)"
echo ""
echo "或者运行: xcodebuild -project CloudDrive.xcodeproj -scheme CloudDrive clean build"

