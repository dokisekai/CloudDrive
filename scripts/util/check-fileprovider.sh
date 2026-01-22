#!/bin/bash

echo "🔧 CloudDrive FileProvider 诊断工具"
echo "=================================="
echo ""

# 检查系统版本
echo "📱 系统信息:"
sw_vers
echo ""

# 检查Xcode版本
echo "🛠️  Xcode信息:"
xcodebuild -version
echo ""

# 检查已注册的FileProvider扩展
echo "📋 已注册的FileProvider扩展:"
pluginkit -m -p com.apple.FileProvider-nonUI
if [ $? -ne 0 ]; then
    echo "   命令执行失败"
fi

echo ""

# 检查扩展路径是否存在
echo "🔍 检查扩展路径:"
EXTENSION_PATH="./build/Build/Products/Debug/CloudDrive.app/Contents/PlugIns/CloudDriveFileProvider.appex"
if [ -d "$EXTENSION_PATH" ]; then
    echo "   ✅ 扩展路径存在: $EXTENSION_PATH"
    ls -la "$EXTENSION_PATH"
else
    echo "   ❌ 扩展路径不存在: $EXTENSION_PATH"
    echo "   请先构建项目"
    exit 1
fi

echo ""

# 检查Info.plist配置
echo "📝 检查扩展Info.plist:"
INFO_PLIST="$EXTENSION_PATH/Contents/Info.plist"
if [ -f "$INFO_PLIST" ]; then
    echo "   ✅ Info.plist存在"
    # 显示关键配置
    defaults read "$INFO_PLIST" NSExtension
else
    echo "   ❌ Info.plist不存在"
fi

echo ""

# 检查授权文件
echo "🔒 检查扩展授权文件:"
ENTITLEMENTS="$EXTENSION_PATH/Contents/embedded.provisionprofile"
if [ -f "$ENTITLEMENTS" ]; then
    echo "   ✅ 授权文件存在"
    # 提取授权信息
    security cms -D -i "$ENTITLEMENTS" | plutil -convert json - -o -
else
    echo "   ⚠️  授权文件不存在或无法访问"
fi

echo ""

# 尝试手动注册扩展
echo "🔧 尝试手动注册扩展:"
pluginkit -a "$EXTENSION_PATH"
if [ $? -eq 0 ]; then
    echo "   ✅ 扩展注册成功"
else
    echo "   ❌ 扩展注册失败"
fi

echo ""

# 再次检查扩展注册状态
echo "📋 刷新后注册状态:"
pluginkit -m -p com.apple.FileProvider-nonUI

# 检查应用是否已安装
echo ""
echo "📦 检查应用安装状态:"
APP_PATH="./build/Build/Products/Debug/CloudDrive.app"
if [ -d "$APP_PATH" ]; then
    echo "   ✅ 应用存在: $APP_PATH"
    # 检查应用是否已被LaunchServices注册
    lsregister -dump | grep -i "net.aabg.CloudDrive"
else
    echo "   ❌ 应用不存在"
fi

echo ""
echo "=================================="
echo "🔍 诊断完成"