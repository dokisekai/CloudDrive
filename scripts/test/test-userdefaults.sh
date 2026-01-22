#!/bin/bash

echo "======================================"
echo "测试 UserDefaults 数据保存"
echo "======================================"
echo ""

# 检查共享 UserDefaults 中的数据
echo "1️⃣ 检查共享 UserDefaults (group.net.aabg.CloudDrive)"
echo "----------------------------------------"
defaults read group.net.aabg.CloudDrive 2>/dev/null
if [ $? -eq 0 ]; then
    echo ""
    echo "✅ 找到共享 UserDefaults 数据"
else
    echo "❌ 未找到共享 UserDefaults 数据"
fi
echo ""

# 检查标准 UserDefaults
echo "2️⃣ 检查标准 UserDefaults (net.aabg.CloudDrive)"
echo "----------------------------------------"
defaults read net.aabg.CloudDrive 2>/dev/null
if [ $? -eq 0 ]; then
    echo ""
    echo "✅ 找到标准 UserDefaults 数据"
else
    echo "❌ 未找到标准 UserDefaults 数据"
fi
echo ""

# 检查 Group Container 目录
echo "3️⃣ 检查 Group Container 目录"
echo "----------------------------------------"
GROUP_DIR=~/Library/Group\ Containers/group.net.aabg.CloudDrive
if [ -d "$GROUP_DIR" ]; then
    echo "✅ Group Container 目录存在"
    echo "目录内容:"
    ls -la "$GROUP_DIR"
else
    echo "❌ Group Container 目录不存在"
fi
echo ""

# 手动写入测试数据
echo "4️⃣ 手动写入测试数据"
echo "----------------------------------------"
defaults write group.net.aabg.CloudDrive testKey "testValue"
if [ $? -eq 0 ]; then
    echo "✅ 写入成功"
    echo "读取测试数据:"
    defaults read group.net.aabg.CloudDrive testKey
else
    echo "❌ 写入失败"
fi
echo ""

echo "======================================"
echo "测试完成"
echo "======================================"