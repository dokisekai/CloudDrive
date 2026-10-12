#!/bin/bash
set -e

# ==============================================================================
# CloudDrive 本地一键激活与权限重签名脚本 / Local Activation & Entitlement Tool
# ==============================================================================
# 功能 / Features:
# 1. 自动清除网络下载导致的 macOS 隔离标记 / Clear Gatekeeper quarantine attributes
# 2. 在用户本机就地执行 Ad-hoc 或个人证书签名 / Perform local code-signing (Ad-hoc or Personal Team)
# 3. 严格注入 App Group (group.net.aabg.CloudDrive) 与 Sandbox 特权 / Inject App Group & Sandbox entitlements
# 4. 注册 File Provider 系统扩展并重启守护进程 / Register File Provider extension and reload Finder
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=================================================="
echo -e "🚀 CloudDrive 本地激活与权限修复工具"
echo -e "   CloudDrive Local Activation & Entitlement Tool"
echo -e "==================================================${NC}"

# 1. 确定目标 App 路径 / Detect Target App Path
TARGET_APP="${1:-/Applications/CloudDrive.app}"

if [ ! -d "$TARGET_APP" ]; then
    if [ -d "./CloudDrive.app" ]; then
        echo -e "${YELLOW}ℹ️ 检测到当前目录下存在 CloudDrive.app，正在安装到 /Applications...${NC}"
        echo -e "${YELLOW}   Found CloudDrive.app in current directory, installing to /Applications...${NC}"
        rm -rf /Applications/CloudDrive.app 2>/dev/null || sudo rm -rf /Applications/CloudDrive.app
        cp -R "./CloudDrive.app" /Applications/
        TARGET_APP="/Applications/CloudDrive.app"
    elif [ -d "../CloudDrive.app" ]; then
        echo -e "${YELLOW}ℹ️ 检测到上级目录下存在 CloudDrive.app，正在安装到 /Applications...${NC}"
        echo -e "${YELLOW}   Found CloudDrive.app in parent directory, installing to /Applications...${NC}"
        rm -rf /Applications/CloudDrive.app 2>/dev/null || sudo rm -rf /Applications/CloudDrive.app
        cp -R "../CloudDrive.app" /Applications/
        TARGET_APP="/Applications/CloudDrive.app"
    else
        echo -e "${RED}❌ 未在 /Applications 找到 CloudDrive.app。${NC}"
        echo -e "${RED}   CloudDrive.app not found in /Applications.${NC}"
        echo -e "请先将 CloudDrive.app 移动至 /Applications 目录，或传入 App 所在绝对路径："
        echo -e "Please move CloudDrive.app to /Applications or provide its path:"
        echo -e "用法 / Usage: $0 /path/to/CloudDrive.app"
        exit 1
    fi
fi

EXT_PATH="$TARGET_APP/Contents/PlugIns/CloudDriveFileProvider.appex"
if [ ! -d "$EXT_PATH" ]; then
    echo -e "${RED}❌ 未在 App 内部找到 CloudDriveFileProvider.appex 系统扩展！${NC}"
    echo -e "${RED}   CloudDriveFileProvider.appex extension not found inside App bundle!${NC}"
    echo -e "请确认安装包完整。 / Please make sure the app bundle is intact."
    exit 1
fi

echo -e "📦 目标程序 / App Path:       ${GREEN}$TARGET_APP${NC}"
echo -e "🔌 系统扩展 / Extension Path:  ${GREEN}$EXT_PATH${NC}"

# 2. 终止正在运行的旧进程 / Terminate running processes
echo -e "\n${BLUE}[1/6] 终止可能正在运行的旧实例 / Terminating running instances...${NC}"
killall -9 CloudDrive 2>/dev/null || true
killall -9 CloudDriveFileProvider 2>/dev/null || true

# 3. 清除 macOS 下载隔离属性 / Clear macOS Quarantine flag
echo -e "\n${BLUE}[2/6] 清除网络下载隔离属性 / Clearing Gatekeeper quarantine...${NC}"
xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true
xattr -cr "$TARGET_APP" 2>/dev/null || true
echo -e "${GREEN}✓ 隔离标记已清除 / Quarantine attributes cleared${NC}"

# 4. 生成自包含的 Entitlements 授权配置 / Generate self-contained Entitlements
TEMP_DIR=$(mktemp -d /tmp/clouddrive_activate.XXXXXX)
trap 'rm -rf "$TEMP_DIR"' EXIT

APP_ENTITLEMENTS="$TEMP_DIR/CloudDrive.entitlements"
EXT_ENTITLEMENTS="$TEMP_DIR/CloudDriveFileProvider.entitlements"

cat << 'EOF' > "$APP_ENTITLEMENTS"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.net.aabg.CloudDrive</string>
	</array>
	<key>com.apple.security.files.bookmarks.app-scope</key>
	<true/>
	<key>com.apple.security.files.bookmarks.document-scope</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-write</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.network.server</key>
	<true/>
</dict>
</plist>
EOF

cat << 'EOF' > "$EXT_ENTITLEMENTS"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.net.aabg.CloudDrive</string>
	</array>
	<key>com.apple.security.files.bookmarks.app-scope</key>
	<true/>
	<key>com.apple.security.files.bookmarks.document-scope</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-write</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.network.server</key>
	<false/>
</dict>
</plist>
EOF

# 5. 检测本机签名身份 / Match local codesigning identity
echo -e "\n${BLUE}[3/6] 匹配本机代码签名身份 / Checking codesigning identity...${NC}"
VALID_IDENTITY=$(security find-identity -p codesigning -v 2>/dev/null | grep "Apple Development:" | head -n 1 | awk -F '"' '{print $2}' || true)

if [ -n "$VALID_IDENTITY" ]; then
    echo -e "   检测到本地开发证书: ${GREEN}$VALID_IDENTITY${NC}"
    echo -e "   Found Apple Development certificate: ${GREEN}$VALID_IDENTITY${NC}"
    SIGN_IDENTITY="$VALID_IDENTITY"
else
    echo -e "   未检测到 Apple Development 证书，使用 ${YELLOW}本机 Ad-hoc 签名 (-)${NC}"
    echo -e "   No Developer certificate found, falling back to ${YELLOW}Ad-hoc signing (-)${NC}"
    SIGN_IDENTITY="-"
fi

# 6. 从内到外严格执行本地代码签名 / Code sign inside-out
echo -e "\n${BLUE}[4/6] 正在为各组件执行就地代码重签名 / Re-signing components inside-out...${NC}"

# 6.1 签名 Frameworks 与 dylib
if [ -d "$TARGET_APP/Contents/Frameworks" ]; then
    find "$TARGET_APP/Contents/Frameworks" -type f \( -name "*.dylib" -o -name "*.framework" \) -exec codesign --force --sign "$SIGN_IDENTITY" {} \; 2>/dev/null || true
fi
if [ -d "$EXT_PATH/Contents/Frameworks" ]; then
    find "$EXT_PATH/Contents/Frameworks" -type f \( -name "*.dylib" -o -name "*.framework" \) -exec codesign --force --sign "$SIGN_IDENTITY" {} \; 2>/dev/null || true
fi

# 6.2 签名 FileProvider Extension (注入扩展专用 Entitlements)
codesign --force --sign "$SIGN_IDENTITY" \
    --entitlements "$EXT_ENTITLEMENTS" \
    "$EXT_PATH"
echo -e "   ✓ 系统扩展已签名并注入 App Group 特权 / Extension signed with App Group"

# 6.3 签名主程序 App (注入主程序 Entitlements)
codesign --force --sign "$SIGN_IDENTITY" \
    --entitlements "$APP_ENTITLEMENTS" \
    "$TARGET_APP"
echo -e "   ✓ 主程序已完成代码签名 / Main application signed successfully"

# 7. 注册 LaunchServices 与 PlugInKit 扩展 / Register LaunchServices & PlugInKit
echo -e "\n${BLUE}[5/6] 向系统注册 App 与 FileProvider Extension / Registering system extension...${NC}"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET_APP"
pluginkit -a "$EXT_PATH"
pluginkit -e use -i net.aabg.CloudDrive.CloudDriveFileProvider 2>/dev/null || true
echo -e "${GREEN}✓ 扩展已注册至系统 PlugInKit / Registered with PlugInKit${NC}"

# 8. 重启系统级 FileProvider 守护进程与访达 / Restart fileproviderd & Finder
echo -e "\n${BLUE}[6/6] 重启 fileproviderd 与访达 (Finder) / Restarting fileproviderd & Finder...${NC}"
killall -9 fileproviderd 2>/dev/null || true
killall Finder 2>/dev/null || true

# 9. 启动程序 / Launch application
echo -e "\n🎉 正在启动 CloudDrive / Launching CloudDrive..."
open -a "$TARGET_APP"

echo -e "\n${GREEN}=================================================="
echo -e "✨ 激活完成！ / Activation Complete!"
echo -e "==================================================${NC}"
echo -e "提示 / Next steps:"
echo -e "1. CloudDrive 菜单栏图标已在屏幕右上角启动。"
echo -e "   CloudDrive icon is now running in the menu bar (top right)."
echo -e "2. 在应用中添加并解锁保险库后，Finder 侧边栏的【位置】将自动呈现虚拟磁盘。"
echo -e "   Add & unlock your vault; the virtual disk will mount directly under Finder > Locations."
