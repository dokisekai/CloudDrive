#!/bin/bash

echo "======================================"
echo "File Provider 诊断工具"
echo "======================================"
echo ""

# 1. 检查 File Provider Extension 是否已安装
echo "1️⃣ 检查 File Provider Extension 安装状态"
echo "----------------------------------------"
pluginkit -m -v | grep CloudDrive
echo ""

# 2. 检查 File Provider Domain 是否已注册
echo "2️⃣ 检查已注册的 File Provider Domains"
echo "----------------------------------------"
if [ -f ~/Library/Group\ Containers/group.net.aabg.CloudDrive/.CloudDrive/domains.json ]; then
    echo "✅ 找到 domains.json"
    cat ~/Library/Group\ Containers/group.net.aabg.CloudDrive/.CloudDrive/domains.json | python3 -m json.tool 2>/dev/null || cat ~/Library/Group\ Containers/group.net.aabg.CloudDrive/.CloudDrive/domains.json
else
    echo "❌ 未找到 domains.json"
fi
echo ""

# 3. 检查保险库信息
echo "3️⃣ 检查保存的保险库信息"
echo "----------------------------------------"
defaults read group.net.aabg.CloudDrive savedVaults 2>/dev/null || echo "❌ 未找到保存的保险库"
echo ""

# 4. 检查 File Provider 进程
echo "4️⃣ 检查 File Provider 进程"
echo "----------------------------------------"
ps aux | grep CloudDriveFileProvider | grep -v grep
if [ $? -eq 0 ]; then
    echo "✅ File Provider 进程正在运行"
else
    echo "❌ File Provider 进程未运行"
fi
echo ""

# 5. 检查挂载点
echo "5️⃣ 检查文件系统挂载点"
echo "----------------------------------------"
mount | grep CloudDrive
if [ $? -eq 0 ]; then
    echo "✅ 找到 CloudDrive 挂载点"
else
    echo "❌ 未找到 CloudDrive 挂载点"
fi
echo ""

# 6. 检查 File Provider 日志
echo "6️⃣ 最近的 File Provider 日志（最近 1 分钟）"
echo "----------------------------------------"
log show --predicate 'processImagePath CONTAINS "CloudDriveFileProvider"' --last 1m --style compact
echo ""

# 7. 检查 entitlements
echo "7️⃣ 检查 App 签名和 Entitlements"
echo "----------------------------------------"
APP_PATH="/Applications/CloudDrive.app"
if [ -d "$APP_PATH" ]; then
    echo "主应用 Entitlements:"
    codesign -d --entitlements :- "$APP_PATH" 2>/dev/null | plutil -p - 2>/dev/null || echo "无法读取"
    echo ""
    echo "File Provider Extension Entitlements:"
    codesign -d --entitlements :- "$APP_PATH/Contents/PlugIns/CloudDriveFileProvider.appex" 2>/dev/null | plutil -p - 2>/dev/null || echo "无法读取"
else
    echo "⚠️ 应用未安装到 /Applications"
    echo "请从 Xcode 构建目录检查"
fi
echo ""

echo "======================================"
echo "诊断完成"
echo "======================================"
echo ""
echo "💡 提示："
echo "1. 如果 File Provider Extension 未安装，需要重新构建并安装应用"
echo "2. 如果 Domain 未注册，需要在应用中创建并解锁保险库"
echo "3. 如果进程未运行，尝试在 Finder 中访问保险库来触发启动"
echo "4. 如果挂载点不存在，File Provider 可能没有正确初始化"