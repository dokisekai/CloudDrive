#!/bin/bash

echo "======================================"
echo "测试 File Provider 文件写入通信"
echo "======================================"
echo ""

# 查找 CloudDrive 虚拟硬盘的挂载点
MOUNT_POINT=$(mount | grep "CloudDrive" | awk '{print $3}' | head -1)

if [ -z "$MOUNT_POINT" ]; then
    echo "❌ 未找到 CloudDrive 虚拟硬盘挂载点"
    echo "请确保："
    echo "1. CloudDrive 应用正在运行"
    echo "2. 已创建并解锁保险库"
    echo "3. 保险库已挂载到 Finder"
    exit 1
fi

echo "✅ 找到挂载点: $MOUNT_POINT"
echo ""

# 创建测试文件
TEST_FILE="$MOUNT_POINT/test_$(date +%s).txt"
echo "📝 创建测试文件: $TEST_FILE"
echo "这是一个测试文件，创建于 $(date)" > "$TEST_FILE"

if [ $? -eq 0 ]; then
    echo "✅ 文件创建成功"
    echo ""
    echo "现在查看主应用日志，应该看到："
    echo "  📤 FileProviderSync: 发送文件变化通知"
    echo "  📢 AppState: 收到 File Provider 文件变化通知"
    echo ""
    echo "等待 3 秒后删除测试文件..."
    sleep 3
    rm "$TEST_FILE"
    echo "✅ 测试文件已删除"
else
    echo "❌ 文件创建失败"
    exit 1
fi

echo ""
echo "======================================"
echo "测试完成！"
echo "======================================"