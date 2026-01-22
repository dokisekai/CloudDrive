#!/bin/bash

# CloudDrive 日志查看脚本

APP_PATH="/Users/snz/Library/Developer/Xcode/DerivedData/CloudDrive-bsjqbgoyvvpkcjguocaafjnxjvaj/Build/Products/Debug/CloudDrive.app"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀 CloudDrive 调试启动器"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 检查应用是否存在
if [ ! -d "$APP_PATH" ]; then
    echo "❌ 应用不存在: $APP_PATH"
    echo "请先在 Xcode 中构建应用"
    exit 1
fi

echo "✅ 找到应用: $APP_PATH"
echo ""

# 杀死已运行的实例
echo "🔄 检查并关闭已运行的实例..."
pkill -f "CloudDrive.app" 2>/dev/null
sleep 1

# 清理旧日志（可选）
read -p "是否清理旧数据？(y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "🗑️  清理旧数据..."
    rm -rf ~/Library/Application\ Support/CloudDrive/
    rm -rf ~/Library/Group\ Containers/group.com.clouddrive.shared/
    echo "✅ 清理完成"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 开始捕获日志..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 启动日志捕获（后台）
LOG_FILE=~/Desktop/clouddrive_$(date +%Y%m%d_%H%M%S).log
log stream --process CloudDrive --level debug > "$LOG_FILE" 2>&1 &
LOG_PID=$!

echo "💾 日志保存到: $LOG_FILE"
echo ""

# 等待一下让日志系统准备好
sleep 1

# 启动应用
echo "🚀 启动应用..."
open "$APP_PATH"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 应用已启动"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📋 实时日志（按 Ctrl+C 停止）："
echo ""

# 实时显示日志
tail -f "$LOG_FILE"

# 清理
kill $LOG_PID 2>/dev/null