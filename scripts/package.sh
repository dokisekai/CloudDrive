#!/bin/bash
set -e

# ==============================================================================
# CloudDrive Release 打包发布脚本 / Release Packaging Script
# ==============================================================================
# 生成适用于免 Xcode 分发给其他用户的免安包 (包含 CloudDrive.app, activate.sh, README.txt)
# Generates release zip with CloudDrive.app, activate.sh, and bilingual README.txt
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo "=================================================="
echo "📦 开始打包 CloudDrive 免 Xcode 分发包"
echo "   Packaging CloudDrive Distribution Archive..."
echo "=================================================="

# 1. 确保已运行编译或直接编译 Release 产物
CONFIGURATION="${1:-Release}"

if [ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild" ]; then
    XCODEBUILD="/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
elif command -v xcodebuild >/dev/null 2>&1; then
    XCODEBUILD="xcodebuild"
else
    echo "❌ 未找到 xcodebuild，打包需要 Xcode 环境。"
    echo "   xcodebuild not found. Full Xcode is required to build packages."
    exit 1
fi

echo "🔨 正在构建 Universal 通用二进制 (${CONFIGURATION} 配置，支持 Apple Silicon arm64 + Intel x86_64)..."
echo "   Building Universal Binary (${CONFIGURATION}, arm64 + x86_64)..."
BUILD_LOG=$(mktemp /tmp/clouddrive_pkg_build.XXXXXX.log)
if ! "$XCODEBUILD" -scheme CloudDrive -configuration "$CONFIGURATION" build ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO > "$BUILD_LOG" 2>&1; then
    echo "❌ 编译失败 / Build failed. Log tail:"
    tail -n 20 "$BUILD_LOG"
    exit 1
fi
rm -f "$BUILD_LOG"

# 2. 定位构建产物
BUILD_PRODUCTS_DIR=$("$XCODEBUILD" -scheme CloudDrive -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null | grep -m 1 "TARGET_BUILD_DIR =" | awk '{print $3}')
if [ -z "$BUILD_PRODUCTS_DIR" ] || [ ! -d "$BUILD_PRODUCTS_DIR/CloudDrive.app" ]; then
    BUILD_PRODUCTS_DIR=$(find "$HOME/Library/Developer/Xcode/DerivedData" -name "CloudDrive.app" -type d -path "*/Build/Products/${CONFIGURATION}/*" 2>/dev/null | head -n 1 | xargs dirname)
fi

APP_PATH="$BUILD_PRODUCTS_DIR/CloudDrive.app"
if [ ! -d "$APP_PATH" ]; then
    echo "❌ 未找到构建产物 / App binary not found: $APP_PATH"
    exit 1
fi

DIST_DIR="$REPO_ROOT/build/dist"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

echo "📂 正在整理打包目录 / Organizing distribution directory..."
cp -R "$APP_PATH" "$DIST_DIR/"
mkdir -p "$DIST_DIR/CloudDrive.app/Contents/PlugIns/CloudDriveFileProvider.appex/Contents/Resources"
if [ -f "$DIST_DIR/CloudDrive.app/Contents/Resources/AppIcon.icns" ]; then
    cp "$DIST_DIR/CloudDrive.app/Contents/Resources/AppIcon.icns" "$DIST_DIR/CloudDrive.app/Contents/PlugIns/CloudDriveFileProvider.appex/Contents/Resources/"
fi
cp "$SCRIPT_DIR/activate.sh" "$DIST_DIR/"
chmod +x "$DIST_DIR/activate.sh"

echo "🔍 验证架构 / Verified architectures:"
echo "   - App:       $(lipo -info "$DIST_DIR/CloudDrive.app/Contents/MacOS/CloudDrive" | sed 's/Architectures in the fat file: .* are: //; s/Non-fat file: .* is architecture: //')"
echo "   - Extension: $(lipo -info "$DIST_DIR/CloudDrive.app/Contents/PlugIns/CloudDriveFileProvider.appex/Contents/MacOS/CloudDriveFileProvider" | sed 's/Architectures in the fat file: .* are: //; s/Non-fat file: .* is architecture: //')"

# 生成中英双语详细说明文件 / Generate bilingual README.txt
cat << 'EOF' > "$DIST_DIR/README.txt"
================================================================================
CloudDrive - Native macOS File Provider for WebDAV and Cryptomator
面向 WebDAV 与 Cryptomator 的原生 macOS File Provider 客户端
================================================================================

[English]
Native macOS File Provider for Cryptomator + WebDAV — encrypted files appear directly in Finder and download only when opened. Free and open source.
GitHub: https://github.com/dokisekai/CloudDrive

Pro-Tip: Pair with Alist (https://github.com/alist-org/alist) to turn 30+ cloud drives
(OneDrive, Google Drive, Baidu, Quark, 115, PikPak, S3, etc.) into Cryptomator-encrypted
native Finder virtual disks with on-demand streaming!

This standalone package is pre-built for Mac users without Xcode.

Quick Installation Steps:
1. Drag and drop "CloudDrive.app" into your "/Applications" folder.
2. Run the bundled activation script "activate.sh" in Terminal:
   bash activate.sh
   (Or: chmod +x activate.sh && ./activate.sh)
3. The script automatically:
   - Removes macOS Gatekeeper quarantine ("App is damaged" prompt);
   - Injects local sandbox and App Group privileges on your Mac;
   - Registers the Apple File Provider extension and reloads Finder.
4. After activation, CloudDrive will launch in the top-right menu bar.
   Add and unlock your WebDAV vault to see it appear directly under Locations
   in Finder!

System Requirements: macOS 15.0 (Sequoia) or later, Universal 2 (Apple Silicon or Intel Mac).

--------------------------------------------------------------------------------

[简体中文]
面向 Cryptomator + WebDAV 的原生 macOS File Provider — 加密文件直接在访达 (Finder) 中显示，仅在打开时按需流式下载。完全免费且开源。
开源地址: https://github.com/dokisekai/CloudDrive

黄金搭档：搭配 Alist (https://github.com/alist-org/alist) 可将百度网盘、夸克网盘、阿里云盘、
115、OneDrive、Google Drive、PikPak、天翼云等数十种网盘一网打尽，秒变原生零知识加密访达虚拟盘！

本分发包已预编译就绪，专为无需安装 Xcode 开发工具链的 Mac 用户准备。

安装使用步骤：
1. 将本目录下的 "CloudDrive.app" 拖动或复制到您的【访达 -> 应用程序】(/Applications) 中。
2. 打开终端，进入解压目录并运行本包附带的激活脚本：
   bash activate.sh
   （或直接双击运行，或在终端输入：chmod +x activate.sh && ./activate.sh）
3. 激活脚本将在 1~2 秒内自动执行：
   - 清除网络下载导致的隔离标记（彻底解决“已损坏，移到废纸篓”报错）；
   - 在您的 Mac 本机就地注入 App Sandbox 与 App Group 共享沙盒特权；
   - 注册 macOS File Provider 系统级扩展并自动重启访达 (Finder)。
4. 激活完成后，CloudDrive 将自动在屏幕右上角菜单栏启动。
   在应用中添加并解锁 WebDAV / Cryptomator 保险库后，访达侧边栏的【位置】将立即
   呈现原生虚拟磁盘！

系统要求：macOS 15.0 (Sequoia) 或更高版本，支持 Apple Silicon 及 Intel 芯片。
================================================================================
EOF

# 3. 压缩为 zip
ZIP_NAME="CloudDrive-macOS-${CONFIGURATION}.zip"
rm -f "$REPO_ROOT/build/$ZIP_NAME"
echo "🗜️ 正在压缩生成 $ZIP_NAME ..."
(cd "$DIST_DIR" && zip -r -q -y "$REPO_ROOT/build/$ZIP_NAME" CloudDrive.app activate.sh README.txt)

echo "=================================================="
echo "✅ 打包完成！/ Packaging succeeded!"
echo "   👉 $REPO_ROOT/build/$ZIP_NAME"
echo "=================================================="
