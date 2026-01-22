#!/bin/bash

echo "======================================"
echo "CloudDrive 同步测试脚本"
echo "======================================"
echo ""

# 检查应用是否在运行
APP_NAME="CloudDrive"
if pgrep -x "$APP_NAME" > /dev/null; then
    echo "✅ $APP_NAME 正在运行"
else
    echo "❌ $APP_NAME 未运行，请先启动应用"
    exit 1
fi

echo ""
echo "📋 查看实时日志..."
echo "======================================"
echo ""

# 显示系统日志（包含 NSLog 输出）
echo "1. 主应用日志："
log stream --predicate 'subsystem == "net.aabg.CloudDrive"' --level debug --style compact &
LOG_PID=$!

echo ""
echo "2. File Provider Extension 日志："
log stream --predicate 'processImagePath CONTAINS "CloudDriveFileProvider"' --level debug --style compact &
PROVIDER_PID=$!

echo ""
echo "======================================"
echo "按 Ctrl+C 停止查看日志"
echo "======================================"
echo ""

# 等待用户中断
trap "kill $LOG_PID $PROVIDER_PID 2>/dev/null; exit" INT TERM

wait