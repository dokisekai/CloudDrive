#!/bin/bash

# 测试日志系统

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}🧪 CloudDrive 日志系统测试${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# 1. 检查日志目录
echo -e "${BLUE}1. 检查日志目录...${NC}"
LOG_DIR="$HOME/.CloudDrive/Logs"
SHARED_LOG_DIR="$HOME/Library/Group Containers/group.net.aabg.CloudDrive/.CloudDrive/Logs"

if [ -d "$LOG_DIR" ]; then
    echo -e "${GREEN}✅ 找到日志目录: $LOG_DIR${NC}"
    ACTIVE_LOG_DIR="$LOG_DIR"
elif [ -d "$SHARED_LOG_DIR" ]; then
    echo -e "${GREEN}✅ 找到共享日志目录: $SHARED_LOG_DIR${NC}"
    ACTIVE_LOG_DIR="$SHARED_LOG_DIR"
else
    echo -e "${YELLOW}⚠️  日志目录不存在，将在应用启动时创建${NC}"
    ACTIVE_LOG_DIR=""
fi
echo ""

# 2. 检查日志文件
if [ -n "$ACTIVE_LOG_DIR" ]; then
    echo -e "${BLUE}2. 检查日志文件...${NC}"
    
    for category in system file-operations webdav cache database; do
        files=$(ls "$ACTIVE_LOG_DIR"/${category}-*.log 2>/dev/null | wc -l)
        if [ $files -gt 0 ]; then
            latest=$(ls -t "$ACTIVE_LOG_DIR"/${category}-*.log 2>/dev/null | head -1)
            size=$(du -h "$latest" 2>/dev/null | cut -f1)
            echo -e "${GREEN}✅ $category: $files 个文件, 最新: $size${NC}"
        else
            echo -e "${YELLOW}⚠️  $category: 无日志文件${NC}"
        fi
    done
    echo ""
fi

# 3. 检查应用是否在运行
echo -e "${BLUE}3. 检查应用状态...${NC}"
if pgrep -f "CloudDrive.app" > /dev/null; then
    echo -e "${GREEN}✅ CloudDrive 正在运行${NC}"
    APP_RUNNING=true
else
    echo -e "${YELLOW}⚠️  CloudDrive 未运行${NC}"
    APP_RUNNING=false
fi
echo ""

# 4. 测试系统日志
echo -e "${BLUE}4. 测试系统日志访问...${NC}"
if log show --predicate 'subsystem == "net.aabg.CloudDrive"' --last 1m --info 2>/dev/null | head -1 > /dev/null; then
    echo -e "${GREEN}✅ 可以访问系统日志${NC}"
    
    # 显示最近的日志
    recent_logs=$(log show --predicate 'subsystem == "net.aabg.CloudDrive"' --last 5m --info 2>/dev/null | tail -5)
    if [ -n "$recent_logs" ]; then
        echo -e "${CYAN}最近的系统日志:${NC}"
        echo "$recent_logs"
    fi
else
    echo -e "${YELLOW}⚠️  无法访问系统日志或没有最近的日志${NC}"
fi
echo ""

# 5. 显示使用建议
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}📋 使用建议${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ "$APP_RUNNING" = true ]; then
    echo -e "${GREEN}✅ 应用正在运行，可以开始测试日志功能${NC}"
    echo ""
    echo -e "${BLUE}推荐测试步骤：${NC}"
    echo ""
    echo -e "  ${YELLOW}方法 1: 在 Xcode 中查看${NC}"
    echo "    1. 打开 Xcode"
    echo "    2. 查看底部控制台面板"
    echo "    3. 搜索 'FILE-OPERATIONS' 或 'ERROR'"
    echo ""
    echo -e "  ${YELLOW}方法 2: 实时监控系统日志${NC}"
    echo "    在新终端运行："
    echo -e "    ${CYAN}log stream --predicate 'subsystem == \"net.aabg.CloudDrive\"' --level debug${NC}"
    echo ""
    echo -e "  ${YELLOW}方法 3: 使用日志查看工具${NC}"
    echo "    在新终端运行："
    echo -e "    ${CYAN}./view_logs.sh${NC}"
    echo "    然后选择选项 7 (实时监控)"
    echo ""
else
    echo -e "${YELLOW}⚠️  应用未运行${NC}"
    echo ""
    echo -e "${BLUE}请先启动应用：${NC}"
    echo ""
    echo -e "  ${YELLOW}方法 1: 在 Xcode 中运行（推荐）${NC}"
    echo "    1. 打开 CloudDrive.xcodeproj"
    echo "    2. 按 Cmd+R 运行"
    echo "    3. 查看 Xcode 控制台的日志输出"
    echo ""
    echo -e "  ${YELLOW}方法 2: 直接运行应用${NC}"
    echo "    然后使用以下命令监控日志："
    echo -e "    ${CYAN}./view_logs.sh${NC}"
    echo ""
fi

# 6. 快速测试选项
if [ "$APP_RUNNING" = true ]; then
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}🚀 快速测试${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -n "是否立即开始实时监控系统日志? (y/N): "
    read -r response
    
    if [[ "$response" =~ ^[Yy]$ ]]; then
        echo ""
        echo -e "${GREEN}开始实时监控...${NC}"
        echo -e "${YELLOW}按 Ctrl+C 停止${NC}"
        echo ""
        sleep 1
        log stream --predicate 'subsystem == "net.aabg.CloudDrive"' --level debug --style compact
    fi
fi

echo ""
echo -e "${GREEN}测试完成！${NC}"
echo ""