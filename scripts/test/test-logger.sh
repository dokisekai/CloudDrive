#!/bin/bash

echo "测试日志系统..."
echo ""

# 检查日志目录
echo "1. 检查日志目录..."
if [ -d ~/.CloudDrive/Logs ]; then
    echo "✅ 日志目录存在"
    ls -lah ~/.CloudDrive/Logs/
else
    echo "❌ 日志目录不存在"
fi

echo ""
echo "2. 检查缓存目录..."
if [ -d ~/.CloudDrive/Cache ]; then
    echo "✅ 缓存目录存在"
    ls -lah ~/.CloudDrive/Cache/
else
    echo "❌ 缓存目录不存在"
fi

echo ""
echo "3. 检查应用是否在运行..."
ps aux | grep CloudDrive | grep -v grep

echo ""
echo "4. 重启应用以触发日志初始化..."
echo "请手动重启 CloudDrive 应用"
echo ""
echo "5. 重启后再次运行此脚本查看日志文件"