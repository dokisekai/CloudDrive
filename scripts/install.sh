#!/bin/bash
set -e

# ==============================================================================
# CloudDrive 一键构建、签名与安装脚本 (支持任意 Mac 电脑)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo "=================================================="
echo "🚀 开始构建 CloudDrive 并安装到 /Applications"
echo "=================================================="

# 检测 xcodebuild 路径
if [ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild" ]; then
    XCODEBUILD="/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
elif command -v xcodebuild >/dev/null 2>&1; then
    XCODEBUILD="xcodebuild"
else
    echo "❌ 未找到 xcodebuild，请确保已安装 Xcode。"
    exit 1
fi

# 1. 关闭正在运行的实例
killall -9 CloudDrive 2>/dev/null || true
killall -9 CloudDriveFileProvider 2>/dev/null || true

# 2. 解析 SPM 依赖包
echo "📦 解析 Swift Package 依赖..."
"$XCODEBUILD" -resolvePackageDependencies -scheme CloudDrive 2>&1 | grep -E "(Resolving|Fetching|Completed)" || true

# 3. 自动检测并修复 CryptomatorCryptoLib 死循环 Bug
echo "🔧 检查并修补第三方库补丁..."
DERIVED_DATA_DIRS=$(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 2 -name "SourcePackages" 2>/dev/null || true)
PATCH_FILE="$SCRIPT_DIR/patches/cryptolib-swift.patch"

for DD in $DERIVED_DATA_DIRS; do
    CRYPTOR_DIR="$DD/checkouts/cryptolib-swift"
    if [ -d "$CRYPTOR_DIR" ]; then
        if git -C "$CRYPTOR_DIR" apply --check "$PATCH_FILE" 2>/dev/null; then
            echo "   应用 Cryptor.swift 补丁到: $CRYPTOR_DIR"
            git -C "$CRYPTOR_DIR" apply "$PATCH_FILE"
        else
            echo "   Cryptor.swift 补丁已就绪或不适用: $CRYPTOR_DIR"
        fi
    fi
done

# 4. 编译项目 (Debug 配置)
echo "🔨 正在编译 CloudDrive..."
BUILD_LOG=$(mktemp /tmp/clouddrive_build.XXXXXX.log)
if ! "$XCODEBUILD" -scheme CloudDrive -configuration Debug build CODE_SIGNING_ALLOWED=NO > "$BUILD_LOG" 2>&1; then
    echo "❌ 编译失败，日志最后 20 行："
    tail -n 20 "$BUILD_LOG"
    rm -f "$BUILD_LOG"
    exit 1
fi
rm -f "$BUILD_LOG"
echo "✅ 编译成功！"

# 5. 定位构建产物
BUILD_PRODUCTS_DIR=$("$XCODEBUILD" -scheme CloudDrive -configuration Debug -showBuildSettings 2>/dev/null | grep -m 1 "TARGET_BUILD_DIR =" | awk '{print $3}')
if [ -z "$BUILD_PRODUCTS_DIR" ] || [ ! -d "$BUILD_PRODUCTS_DIR/CloudDrive.app" ]; then
    # 回退到 DerivedData 查找
    BUILD_PRODUCTS_DIR=$(find "$HOME/Library/Developer/Xcode/DerivedData" -name "CloudDrive.app" -type d -path "*/Build/Products/Debug/*" 2>/dev/null | head -n 1 | xargs dirname)
fi

APP_PATH="$BUILD_PRODUCTS_DIR/CloudDrive.app"
EXT_PATH="$APP_PATH/Contents/PlugIns/CloudDriveFileProvider.appex"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ 未找到构建好的 CloudDrive.app"
    exit 1
fi

# 6. 选择最佳代码签名身份
echo "🔐 检测代码签名证书..."
VALID_IDENTITY=$(security find-identity -p codesigning -v 2>/dev/null | grep "Apple Development:" | head -n 1 | awk -F '"' '{print $2}' || true)

if [ -n "$VALID_IDENTITY" ]; then
    echo "   使用本地开发证书签名: $VALID_IDENTITY"
    SIGN_IDENTITY="$VALID_IDENTITY"
else
    echo "   未检测到 Apple Development 证书，使用本地自签名 (-)"
    SIGN_IDENTITY="-"
fi

# 7. 从内到外严格执行签名 (包含 Entitlements 与 Frameworks)
echo "✍️ 正在对组件进行代码签名..."
# 7.1 签名 Frameworks
if [ -d "$APP_PATH/Contents/Frameworks" ]; then
    find "$APP_PATH/Contents/Frameworks" -name "*.framework" -exec codesign --force --sign "$SIGN_IDENTITY" {} \;
fi
if [ -d "$EXT_PATH/Contents/Frameworks" ]; then
    find "$EXT_PATH/Contents/Frameworks" -name "*.framework" -exec codesign --force --sign "$SIGN_IDENTITY" {} \;
fi

# 7.2 签名 Extension (必须嵌入 App Group 和 Sandbox)
codesign --force --sign "$SIGN_IDENTITY" \
    --entitlements "$REPO_ROOT/Sources/CloudDriveFileProvider/CloudDriveFileProvider.entitlements" \
    "$EXT_PATH"

# 7.3 签名主 App
codesign --force --sign "$SIGN_IDENTITY" \
    --entitlements "$REPO_ROOT/Sources/CloudDrive/CloudDrive.entitlements" \
    "$APP_PATH"

echo "✅ 代码签名完成！"

# 8. 覆盖安装到 /Applications
echo "📂 安装到 /Applications/CloudDrive.app..."
rm -rf /Applications/CloudDrive.app
cp -R "$APP_PATH" /Applications/

# 9. 刷新 LaunchServices 与 PlugInKit 注册
echo "🔄 注册 App 与 FileProvider Extension..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/CloudDrive.app
pluginkit -a /Applications/CloudDrive.app/Contents/PlugIns/CloudDriveFileProvider.appex

# 10. 重启系统服务
echo "🔄 重启 fileproviderd 和 Finder..."
killall -9 fileproviderd 2>/dev/null || true
killall Finder 2>/dev/null || true

# 11. 启动 CloudDrive
echo "🎉 正在启动 CloudDrive..."
open -a /Applications/CloudDrive.app

echo "=================================================="
echo "✨ 安装完成！CloudDrive 虚拟盘将自动加载到访达侧边栏。"
echo "=================================================="
