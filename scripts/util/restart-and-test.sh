#!/bin/bash

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔄 重启 FileProvider 并测试上传功能"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 1. 停止 FileProvider
echo ""
echo "1️⃣ 停止 FileProvider Extension..."
pkill -9 -f "CloudDriveFileProvider" || echo "   FileProvider 未运行"

# 2. 清理缓存
echo ""
echo "2️⃣ 清理系统缓存..."
rm -rf ~/Library/Caches/net.aabg.CloudDrive.CloudDriveFileProvider
rm -rf ~/Library/Containers/net.aabg.CloudDrive.CloudDriveFileProvider/Data/Library/Caches

# 3. 重新注册 FileProvider
echo ""
echo "3️⃣ 重新注册 FileProvider..."
pluginkit -a /Users/snz/Library/Developer/Xcode/DerivedData/CloudDrive-*/Build/Products/Debug/CloudDrive.app/Contents/PlugIns/CloudDriveFileProvider.appex
pluginkit -m -v

# 4. 等待系统准备
echo ""
echo "4️⃣ 等待系统准备..."
sleep 3

# 5. 显示日志监控命令
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ FileProvider 已重启"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📋 现在请执行以下操作："
echo ""
echo "1. 在 Finder 中打开 CloudDrive"
echo "2. 创建一个新文件夹或复制一个文件"
echo "3. 观察日志输出"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 实时监控日志（按 Ctrl+C 停止）："
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 6. 监控日志
tail -f "/Users/snz/Library/Group Containers/group.net.aabg.CloudDrive/.CloudDrive/Logs/file-operations-$(date +%Y-%m-%d).log" | grep --line-buffered -E "(创建|上传|VFS|Upload|Create|━━━)"