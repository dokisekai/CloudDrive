#!/bin/bash

# CloudDrive 项目完整性验证脚本

set -e

PROJECT_DIR="/Users/snz/Desktop/CloudDrive"
cd "$PROJECT_DIR"

echo "🔍 CloudDrive 项目完整性验证"
echo "================================"
echo ""

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

TOTAL_FILES=0
MISSING_FILES=0
PRESENT_FILES=0

check_file() {
    TOTAL_FILES=$((TOTAL_FILES + 1))
    if [ -f "$1" ]; then
        echo -e "${GREEN}✅${NC} $1"
        PRESENT_FILES=$((PRESENT_FILES + 1))
        return 0
    else
        echo -e "${RED}❌${NC} $1"
        MISSING_FILES=$((MISSING_FILES + 1))
        return 1
    fi
}

echo "📦 1. CloudDriveCore (Framework)"
echo "--------------------------------"
check_file "CloudDriveCore/CloudFile.swift"
check_file "CloudDriveCore/CacheManager.swift"
check_file "CloudDriveCore/WebDAVClient.swift"
check_file "CloudDriveCore/VirtualFileSystem.swift"
check_file "CloudDriveCore/VFSEncryption.swift"
check_file "CloudDriveCore/VFSDatabase.swift"
echo ""

echo "📱 2. CloudDriveFileProvider (Extension)"
echo "----------------------------------------"
check_file "CloudDriveFileProvider/FileProviderExtension.swift"
check_file "CloudDriveFileProvider/FileProviderItem.swift"
check_file "CloudDriveFileProvider/CloudDriveFileProvider.entitlements"
echo ""

echo "🖥️  3. CloudDrive (主应用)"
echo "-------------------------"
check_file "CloudDrive/CloudDriveApp.swift"
check_file "CloudDrive/ContentView.swift"
check_file "CloudDrive/CreateVaultView.swift"
check_file "CloudDrive/SettingsView.swift"
check_file "CloudDrive/CloudDrive.entitlements"
echo ""

echo "🌐 4. WebServer (Node.js)"
echo "-------------------------"
check_file "WebServer/server.js"
check_file "WebServer/package.json"
check_file "WebServer/.env.example"
echo ""

echo "📄 5. 文档文件"
echo "-------------"
check_file "README.md"
check_file "ARCHITECTURE.md"
check_file "COMPILE_ERRORS_FIX.md"
check_file "FIXES.md"
check_file "READY_TO_BUILD.md"
echo ""

echo "🔧 6. 配置文件"
echo "-------------"
check_file "CloudDrive.xcodeproj/project.pbxproj"
check_file "auto_fix_all.sh"
check_file "fix_bridging_header.sh"
echo ""

# 检查导入语句
echo "🔍 7. 检查导入语句"
echo "-----------------"

check_imports() {
    local file=$1
    local required_import=$2
    
    if [ -f "$file" ]; then
        if grep -q "import $required_import" "$file"; then
            echo -e "${GREEN}✅${NC} $file 包含 'import $required_import'"
        else
            echo -e "${YELLOW}⚠️${NC}  $file 缺少 'import $required_import'"
        fi
    fi
}

check_imports "CloudDriveFileProvider/FileProviderExtension.swift" "CloudDriveCore"
check_imports "CloudDriveFileProvider/FileProviderItem.swift" "CloudDriveCore"
check_imports "CloudDrive/CloudDriveApp.swift" "CloudDriveCore"
check_imports "CloudDrive/ContentView.swift" "CloudDriveCore"
check_imports "CloudDrive/SettingsView.swift" "CloudDriveCore"
echo ""

# 检查重复文件
echo "🔍 8. 检查重复文件"
echo "-----------------"
if [ -f "CloudDriveFileProvider/FileProviderEnumerator.swift" ]; then
    echo -e "${RED}❌${NC} 发现重复文件: CloudDriveFileProvider/FileProviderEnumerator.swift"
    echo "   (应该已被删除，FileProviderEnumerator 在 FileProviderExtension.swift 中)"
else
    echo -e "${GREEN}✅${NC} 无重复文件"
fi
echo ""

# 检查 Bridging Header
echo "🔍 9. 检查 Bridging Header"
echo "-------------------------"
if [ -f "CloudDriveCore/CloudDriveCore-Bridging-Header.h" ]; then
    echo -e "${RED}❌${NC} 发现 Bridging Header 文件 (应该已被删除)"
else
    echo -e "${GREEN}✅${NC} 无 Bridging Header 文件"
fi

if grep -q "SWIFT_OBJC_BRIDGING_HEADER" "CloudDrive.xcodeproj/project.pbxproj" 2>/dev/null; then
    echo -e "${YELLOW}⚠️${NC}  project.pbxproj 中仍包含 Bridging Header 配置"
else
    echo -e "${GREEN}✅${NC} project.pbxproj 中无 Bridging Header 配置"
fi
echo ""

# 检查 App Group
echo "🔍 10. 检查 App Group 配置"
echo "-------------------------"
if grep -q "group.com.clouddrive" "CloudDrive/CloudDrive.entitlements" 2>/dev/null; then
    echo -e "${GREEN}✅${NC} CloudDrive.entitlements 包含 App Group"
else
    echo -e "${YELLOW}⚠️${NC}  CloudDrive.entitlements 缺少 App Group"
fi

if grep -q "group.com.clouddrive" "CloudDriveFileProvider/CloudDriveFileProvider.entitlements" 2>/dev/null; then
    echo -e "${GREEN}✅${NC} CloudDriveFileProvider.entitlements 包含 App Group"
else
    echo -e "${YELLOW}⚠️${NC}  CloudDriveFileProvider.entitlements 缺少 App Group"
fi
echo ""

# 统计
echo "================================"
echo "📊 验证统计"
echo "================================"
echo "总文件数: $TOTAL_FILES"
echo -e "${GREEN}存在: $PRESENT_FILES${NC}"
echo -e "${RED}缺失: $MISSING_FILES${NC}"
echo ""

if [ $MISSING_FILES -eq 0 ]; then
    echo -e "${GREEN}✅ 所有文件都存在！${NC}"
    echo ""
    echo "🎉 项目完整性验证通过！"
    echo ""
    echo "📝 下一步:"
    echo "1. 在 Xcode 中打开项目: open CloudDrive.xcodeproj"
    echo "2. 选择 CloudDrive scheme"
    echo "3. 清理并编译: Cmd+Shift+K 然后 Cmd+B"
    echo ""
    echo "⚠️  可能需要的额外配置:"
    echo "- 添加 libsqlite3.tbd 到 CloudDriveCore target"
    echo "- 配置签名和 App Groups"
    exit 0
else
    echo -e "${RED}❌ 发现 $MISSING_FILES 个缺失文件${NC}"
    echo ""
    echo "请检查并创建缺失的文件"
    exit 1
fi