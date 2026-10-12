#!/bin/bash
# ==============================================================================
# CloudDrive 一键卸载与数据/缓存彻底清理脚本
# CloudDrive Complete Uninstall & Cache Cleanup Tool
# ==============================================================================
# 功能 / Features:
# 1. 终止所有运行中的 CloudDrive 主程序与 FileProvider 扩展进程
# 2. 从系统 PlugInKit 与 LaunchServices 注销扩展与服务注册
# 3. 彻底清除 App Group 共享目录 (本地缓存 Cache、缩略图、VFS 数据库、回收站等)
# 4. 清理沙盒容器 (Containers)、应用脚本 (Application Scripts)、Application Support
# 5. 清理系统偏好设置 (UserDefaults)、已保存应用状态、HTTP 缓存与 WebKit 缓存
# 6. 从 macOS Keychain 安全清理已保存的密码凭据
# 7. 重置 TCC 隐私权限 (文件访问、磁盘权限等授权记录)
# 8. 清除 CloudStorage 虚拟挂载残留并重启 fileproviderd & Finder 刷新侧边栏
# 9. 移除 /Applications/CloudDrive.app (支持 --keep-app 仅重置数据)
# 10. (可选) 清理 Xcode DerivedData 与开发构建产物 (--dev)
# ==============================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 参数默认值
DRY_RUN=0
FORCE=0
KEEP_APP=0
CLEAN_DEV=0

# 解析命令行参数
show_help() {
    echo -e "${BOLD}CloudDrive 一键卸载与彻底清理工具${NC}"
    echo -e "用法 / Usage: $0 [选项 / Options]"
    echo ""
    echo "选项 / Options:"
    echo "  -h, --help        显示此帮助信息 / Show this help message"
    echo "  -n, --dry-run     仅预览将要删除的文件与清理项，不执行实际操作 / Preview only"
    echo "  -y, -f, --force   跳过确认提示，自动执行彻底清理 / Skip confirmation prompt"
    echo "  --keep-app        保留 CloudDrive.app 应用程序本体，仅重置/清理所有缓存、配置与凭据"
    echo "                    (Keep CloudDrive.app, only reset data & caches)"
    echo "  --dev             同时清理开发构建产物 (DerivedData, ./build, SPM 缓存)"
    echo "                    (Also purge Xcode DerivedData and local build artifacts)"
    echo ""
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            ;;
        -n|--dry-run)
            DRY_RUN=1
            shift
            ;;
        -y|-f|--force)
            FORCE=1
            shift
            ;;
        --keep-app)
            KEEP_APP=1
            shift
            ;;
        --dev)
            CLEAN_DEV=1
            shift
            ;;
        *)
            echo -e "${RED}❌ 未知参数: $1${NC}"
            echo -e "使用 $0 --help 查看支持的选项。"
            exit 1
            ;;
    esac
done

echo -e "${BLUE}=================================================="
echo -e "🧹 CloudDrive 一键卸载与数据/缓存彻底清理工具"
echo -e "   CloudDrive Complete Uninstall & Cache Cleanup"
echo -e "==================================================${NC}"

if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "${YELLOW}🔍 当前运行模式: [DRY-RUN 预览模式]，不会进行任何实际修改。${NC}\n"
fi

if [ "$KEEP_APP" -eq 1 ]; then
    echo -e "${CYAN}ℹ️ 已开启 --keep-app: 将保留 CloudDrive.app，仅清理所有数据与缓存 (一键重置)。${NC}\n"
fi

# 安全校验函数：严禁误删系统级或非本应用目录
is_safe_to_delete() {
    local p="$1"
    [ -z "$p" ] && return 1
    # 绝对禁止路径
    if [[ "$p" == "/" || "$p" == "$HOME" || "$p" == "$HOME/Library" || \
          "$p" == "$HOME/Library/CloudStorage" || "$p" == "$HOME/Library/Group Containers" || \
          "$p" == "$HOME/Library/Containers" || "$p" == "$HOME/Library/Preferences" || \
          "$p" == "$HOME/Library/Caches" || "$p" == "$HOME/Library/Application Support" || \
          "$p" == "$HOME/Library/Application Scripts" || "$p" == "/Applications" ]]; then
        return 1
    fi
    # 严禁匹配系统级 iCloudDrive 与 Apple 内部组件
    if [[ "$p" =~ iCloudDrive ]] || [[ "$p" =~ com\.apple\.CloudDocs ]] || [[ "$p" =~ group\.com\.apple ]]; then
        return 1
    fi
    return 0
}

# 删除单个目标路径（支持自动解除锁定与 sudo 回退）
remove_target() {
    local target="$1"
    local desc="$2"

    if ! is_safe_to_delete "$target"; then
        echo -e "   ${RED}⚠️ 安全拦截: 跳过不安全路径 $target${NC}"
        return 1
    fi

    if [ -e "$target" ] || [ -d "$target" ] || [ -L "$target" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            echo -e "   ${YELLOW}[预览] 将删除:${NC} $target ${CYAN}($desc)${NC}"
            return 0
        fi

        # 尝试解除文件锁定
        chflags -R noschg,nouchg "$target" 2>/dev/null || true

        if rm -rf "$target" 2>/dev/null; then
            echo -e "   ${GREEN}✓ 已删除:${NC} $target ${CYAN}($desc)${NC}"
            return 0
        else
            # 普通权限删除失败，尝试 sudo (若终端有权限或免密)
            if sudo -n rm -rf "$target" 2>/dev/null || ( [ -t 0 ] && sudo rm -rf "$target" 2>/dev/null ); then
                echo -e "   ${GREEN}✓ 已通过管理员权限删除:${NC} $target ${CYAN}($desc)${NC}"
                return 0
            else
                echo -e "   ${YELLOW}⚠️ 无法直接删除 (可能需在系统设置中为终端授予完全磁盘访问权限):${NC} $target"
                return 1
            fi
        fi
    fi
    return 0
}

# 交互确认
if [ "$FORCE" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
    echo -e "${YELLOW}⚠️ 注意 / WARNING:${NC}"
    if [ "$KEEP_APP" -eq 1 ]; then
        echo -e "该操作将彻底清理 CloudDrive 的所有本地缓存、挂载磁盘、数据库、配置文件与钥匙串密码！"
        echo -e "应用程序 CloudDrive.app 本身将被保留，重置为初次安装状态。"
    else
        echo -e "该操作将彻底卸载 CloudDrive，并清理所有本地缓存、挂载磁盘、数据库、配置文件与钥匙串密码！"
    fi
    echo ""
    read -r -p "确定要继续清理吗？/ Are you sure you want to proceed? [y/N]: " CONFIRM
    case "$CONFIRM" in
        [yY][eE][sS]|[yY])
            echo -e "\n开始执行清理流程...\n"
            ;;
        *)
            echo -e "\n已取消操作。/ Operation cancelled."
            exit 0
            ;;
    esac
fi

# ==============================================================================
# 步骤 1: 终止正在运行的进程
# ==============================================================================
echo -e "${BLUE}[1/10] 终止正在运行的 CloudDrive 进程 / Terminating running processes...${NC}"
if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "   ${YELLOW}[预览] 将终止进程:${NC} CloudDrive, CloudDriveFileProvider, CloudDriveTestsRunner"
else
    RUNNING_PIDS=$(pgrep -f "CloudDrive" 2>/dev/null | grep -v "$$" || true)
    if [ -n "$RUNNING_PIDS" ]; then
        killall -9 CloudDrive 2>/dev/null || true
        killall -9 CloudDriveFileProvider 2>/dev/null || true
        killall -9 CloudDriveTestsRunner 2>/dev/null || true
        sleep 1
        echo -e "   ${GREEN}✓ 相关进程已成功终止${NC}"
    else
        echo -e "   ℹ️ 未检测到正在运行的 CloudDrive 进程"
    fi
fi

# ==============================================================================
# 步骤 2: 注销 PlugInKit 系统扩展与 LaunchServices 注册
# ==============================================================================
echo -e "\n${BLUE}[2/10] 注销 FileProvider 系统扩展与 LaunchServices 注册...${NC}"
if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "   ${YELLOW}[预览] 将注销 PlugInKit 扩展:${NC} net.aabg.CloudDrive.CloudDriveFileProvider / net.aabg.CloudDrive.FileProvider"
    echo -e "   ${YELLOW}[预览] 将从 LaunchServices 注销 /Applications/CloudDrive.app${NC}"
else
    pluginkit -r "/Applications/CloudDrive.app/Contents/PlugIns/CloudDriveFileProvider.appex" 2>/dev/null || true
    pluginkit -r "$HOME/Applications/CloudDrive.app/Contents/PlugIns/CloudDriveFileProvider.appex" 2>/dev/null || true
    pluginkit -r -i net.aabg.CloudDrive.CloudDriveFileProvider 2>/dev/null || true
    pluginkit -r -i net.aabg.CloudDrive.FileProvider 2>/dev/null || true
    pluginkit -e ignore -i net.aabg.CloudDrive.CloudDriveFileProvider 2>/dev/null || true
    pluginkit -e ignore -i net.aabg.CloudDrive.FileProvider 2>/dev/null || true

    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u /Applications/CloudDrive.app 2>/dev/null || true
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$HOME/Applications/CloudDrive.app" 2>/dev/null || true
    echo -e "   ${GREEN}✓ 系统扩展与 LaunchServices 注册已注销${NC}"
fi

# ==============================================================================
# 步骤 3: 刷新 fileproviderd 守护进程与 Finder 侧边栏
# ==============================================================================
echo -e "\n${BLUE}[3/10] 重启 fileproviderd 守护进程与 Finder 释放挂载点...${NC}"
if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "   ${YELLOW}[预览] 将重启:${NC} fileproviderd, Finder"
else
    killall -9 fileproviderd 2>/dev/null || true
    sleep 1
    echo -e "   ${GREEN}✓ fileproviderd 已重启${NC}"
fi

# ==============================================================================
# 步骤 4: 清除 CloudStorage 虚拟挂载点残留
# ==============================================================================
echo -e "\n${BLUE}[4/10] 清理 CloudStorage 虚拟磁盘挂载点残留...${NC}"
if [ -d "$HOME/Library/CloudStorage" ]; then
    # 查找 CloudDrive 相关的挂载目录，坚决排除 iCloudDrive
    for mount_dir in "$HOME/Library/CloudStorage"/CloudDrive* "$HOME/Library/CloudStorage"/net.aabg.CloudDrive*; do
        if [ -e "$mount_dir" ] || [ -d "$mount_dir" ]; then
            if [[ "$mount_dir" =~ iCloudDrive ]]; then
                continue
            fi
            remove_target "$mount_dir" "CloudStorage 虚拟磁盘"
        fi
    done
fi

# ==============================================================================
# 步骤 5: 清理 App Group 共享容器 (核心缓存、VFS 数据库、保险库配置)
# ==============================================================================
echo -e "\n${BLUE}[5/10] 清理 App Group 共享数据与本地文件缓存...${NC}"
# 目标：group.net.aabg.CloudDrive (严禁匹配 group.com.apple.iCloudDrive!)
GROUP_DIR="$HOME/Library/Group Containers/group.net.aabg.CloudDrive"
remove_target "$GROUP_DIR" "App Group 核心数据 (.CloudDrive, Cache, VFS 数据库, 缩略图)"

# ==============================================================================
# 步骤 6: 清理沙盒容器、应用脚本与 Application Support
# ==============================================================================
echo -e "\n${BLUE}[6/10] 清理沙盒容器、脚本与 Application Support...${NC}"
# Containers
remove_target "$HOME/Library/Containers/net.aabg.CloudDrive" "主程序沙盒容器"
remove_target "$HOME/Library/Containers/net.aabg.CloudDrive.CloudDriveFileProvider" "FileProvider 沙盒容器"
remove_target "$HOME/Library/Containers/net.aabg.CloudDrive.FileProvider" "FileProvider 历史容器"
remove_target "$HOME/Library/Containers/net.aabg.CloudDriveUITests.xctrunner" "测试沙盒容器"

# Application Scripts
remove_target "$HOME/Library/Application Scripts/net.aabg.CloudDrive" "主程序 Application Scripts"
remove_target "$HOME/Library/Application Scripts/net.aabg.CloudDrive.CloudDriveFileProvider" "扩展 Application Scripts"
remove_target "$HOME/Library/Application Scripts/net.aabg.CloudDrive.FileProvider" "扩展历史 Application Scripts"
remove_target "$HOME/Library/Application Scripts/group.net.aabg.CloudDrive" "App Group Application Scripts"
remove_target "$HOME/Library/Application Scripts/net.aabg.CloudDriveUITests.xctrunner" "测试 Application Scripts"

# Application Support
remove_target "$HOME/Library/Application Support/.CloudDrive" "Application Support 隐藏数据"
remove_target "$HOME/Library/Application Support/CloudDrive" "Application Support 数据"
remove_target "$HOME/Library/Application Support/net.aabg.CloudDrive" "Application Support 数据"

# ==============================================================================
# 步骤 7: 清理应用 Caches、HTTPStorages、WebKit 与偏好设置 (UserDefaults)
# ==============================================================================
echo -e "\n${BLUE}[7/10] 清理应用 Caches、HTTP 缓存与偏好设置 (UserDefaults)...${NC}"
# Caches
remove_target "$HOME/Library/Caches/net.aabg.CloudDrive" "应用缓存"
remove_target "$HOME/Library/Caches/net.aabg.CloudDrive.CloudDriveFileProvider" "扩展缓存"
remove_target "$HOME/Library/Caches/net.aabg.CloudDrive.FileProvider" "扩展历史缓存"
remove_target "$HOME/Library/Caches/CloudDriveTestsRunner" "测试运行器缓存"

# HTTPStorages & WebKit
remove_target "$HOME/Library/HTTPStorages/net.aabg.CloudDrive" "HTTP 存储缓存"
remove_target "$HOME/Library/HTTPStorages/CloudDriveTestsRunner" "测试 HTTP 存储缓存"
remove_target "$HOME/Library/WebKit/net.aabg.CloudDrive" "WebKit 存储缓存"

# Saved Application State
remove_target "$HOME/Library/Saved Application State/net.aabg.CloudDrive.savedState" "已保存窗口状态"

# Preferences 文件
remove_target "$HOME/Library/Preferences/group.net.aabg.CloudDrive.plist" "App Group 偏好配置"
remove_target "$HOME/Library/Preferences/net.aabg.CloudDrive.plist" "主程序偏好配置"
remove_target "$HOME/Library/Preferences/net.aabg.CloudDrive.CloudDriveFileProvider.plist" "扩展偏好配置"
remove_target "$HOME/Library/Preferences/CloudDriveTestsRunner.plist" "测试偏好配置"

# Defaults 域删除
if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "   ${YELLOW}[预览] 将重置 defaults 偏好设置域:${NC} net.aabg.CloudDrive, group.net.aabg.CloudDrive"
else
    for domain in "net.aabg.CloudDrive" "net.aabg.CloudDrive.CloudDriveFileProvider" "net.aabg.CloudDrive.FileProvider" "group.net.aabg.CloudDrive" "net.aabg.CloudDriveUITests.xctrunner" "CloudDriveTestsRunner"; do
        if defaults read "$domain" >/dev/null 2>&1; then
            defaults delete "$domain" >/dev/null 2>&1 || true
            echo -e "   ${GREEN}✓ 已重置 defaults 偏好设置域:${NC} $domain"
        fi
    done
fi

# ==============================================================================
# 步骤 8: 从 macOS 钥匙串安全清理密码凭据
# ==============================================================================
echo -e "\n${BLUE}[8/10] 从 macOS 钥匙串 (Keychain) 清理已保存凭据...${NC}"
clean_keychain_service() {
    local svc="$1"
    local count=0
    if [ "$DRY_RUN" -eq 1 ]; then
        if security find-generic-password -s "$svc" >/dev/null 2>&1; then
            echo -e "   ${YELLOW}[预览] 发现钥匙串项将清理 (服务: $svc)${NC}"
        fi
        return 0
    fi

    while security find-generic-password -s "$svc" >/dev/null 2>&1; do
        if security delete-generic-password -s "$svc" >/dev/null 2>&1; then
            ((count++))
        else
            break
        fi
    done
    if [ $count -gt 0 ]; then
        echo -e "   ${GREEN}✓ 已从钥匙串移除 $count 项密码凭据 (服务: $svc)${NC}"
    else
        echo -e "   ℹ️ 钥匙串中未找到服务凭据: $svc"
    fi
}

clean_keychain_service "net.aabg.CloudDrive"
clean_keychain_service "group.net.aabg.CloudDrive"
clean_keychain_service "net.aabg.CloudDrive.CloudDriveFileProvider"

# 重置 TCC 隐私授权
if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "   ${YELLOW}[预览] 将重置 TCC 权限:${NC} net.aabg.CloudDrive"
else
    tccutil reset All net.aabg.CloudDrive >/dev/null 2>&1 || true
    tccutil reset All net.aabg.CloudDrive.CloudDriveFileProvider >/dev/null 2>&1 || true
    echo -e "   ${GREEN}✓ 已重置系统 TCC 隐私权限${NC}"
fi

# 日志清理
remove_target "$HOME/Library/Logs/CloudDrive" "应用日志"
for diag_file in "$HOME/Library/Logs/DiagnosticReports"/CloudDrive*; do
    if [ -e "$diag_file" ] && [[ ! "$diag_file" =~ iCloudDrive ]]; then
        remove_target "$diag_file" "崩溃诊断日志"
    fi
done

# ==============================================================================
# 步骤 9: 移除 CloudDrive.app 应用程序本体
# ==============================================================================
echo -e "\n${BLUE}[9/10] 移除 CloudDrive.app 应用程序本体...${NC}"
if [ "$KEEP_APP" -eq 1 ]; then
    echo -e "   ${CYAN}⏩ 已指定 --keep-app，跳过删除应用程序本体。${NC}"
else
    remove_target "/Applications/CloudDrive.app" "应用程序 (/Applications)"
    remove_target "/Applications/CloudDrive 2.app" "历史重名应用 (/Applications)"
    remove_target "$HOME/Applications/CloudDrive.app" "用户目录应用程序 (~/Applications)"
fi

# ==============================================================================
# 步骤 10: 清理开发构建缓存 (可选 --dev) 与最终刷新
# ==============================================================================
echo -e "\n${BLUE}[10/10] 清理构建产物并重启 Finder 刷新界面...${NC}"
if [ "$CLEAN_DEV" -eq 1 ]; then
    echo -e "   🔨 正在清理开发构建缓存 (--dev)..."
    # DerivedData
    for dd in "$HOME/Library/Developer/Xcode/DerivedData"/CloudDrive-*; do
        if [ -d "$dd" ]; then
            remove_target "$dd" "Xcode DerivedData 编译缓存"
        fi
    done
    # 本地仓库产物
    if [ -d "$REPO_ROOT/build" ]; then
        remove_target "$REPO_ROOT/build" "本地 build 目录"
    fi
    if [ -d "$REPO_ROOT/.build" ]; then
        remove_target "$REPO_ROOT/.build" "本地 .build (SPM) 缓存"
    fi
fi

# 最终重启 Finder，使侧边栏虚拟盘与幽灵驱动器彻底消失
if [ "$DRY_RUN" -ne 1 ]; then
    killall Finder 2>/dev/null || true
    echo -e "   ${GREEN}✓ Finder 已重启刷新${NC}"
fi

echo -e "\n${GREEN}=================================================="
if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "✨ 预览完成！以上为所有将被清理的项目。"
elif [ "$KEEP_APP" -eq 1 ]; then
    echo -e "✨ 数据清理与重置完成！CloudDrive 已恢复为全新安装状态。"
else
    echo -e "✨ 卸载与清理完成！CloudDrive 及其所有缓存数据已彻底从本机移除。"
fi
echo -e "==================================================${NC}"
