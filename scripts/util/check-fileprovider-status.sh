#!/bin/bash

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 检查 File Provider 状态"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 检查 File Provider Extension 是否在运行
echo ""
echo "📋 正在运行的 File Provider Extension:"
ps aux | grep "CloudDriveFileProvider" | grep -v grep

# 检查已注册的 Domain
echo ""
echo "📁 已注册的 File Provider Domain:"
pluginkit -m -v -i net.aabg.CloudDrive.CloudDriveFileProvider

# 检查系统日志
echo ""
echo "📝 最近的 File Provider 日志:"
log show --predicate 'subsystem == "com.apple.FileProvider"' --last 5m --info

echo ""
echo "📝 CloudDrive 相关日志:"
log show --predicate 'process == "CloudDrive" OR process CONTAINS "FileProvider"' --last 5m --info

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 检查完成"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"