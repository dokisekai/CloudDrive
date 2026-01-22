#!/bin/bash

# CloudDrive 日志查看工具
# 支持查看文件日志和系统日志

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 日志目录
LOG_DIR="$HOME/.CloudDrive/Logs"
SHARED_LOG_DIR="$HOME/Library/Group Containers/group.net.aabg.CloudDrive/.CloudDrive/Logs"

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}📋 CloudDrive 日志查看工具${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# 检查日志目录
check_log_dir() {
    if [ -d "$LOG_DIR" ]; then
        echo -e "${GREEN}✅ 找到日志目录: $LOG_DIR${NC}"
        return 0
    elif [ -d "$SHARED_LOG_DIR" ]; then
        LOG_DIR="$SHARED_LOG_DIR"
        echo -e "${GREEN}✅ 找到共享日志目录: $LOG_DIR${NC}"
        return 0
    else
        echo -e "${RED}❌ 日志目录不存在${NC}"
        echo -e "${YELLOW}提示: 请先运行应用以创建日志${NC}"
        return 1
    fi
}

# 显示菜单
show_menu() {
    echo ""
    echo -e "${BLUE}请选择查看方式:${NC}"
    echo ""
    echo "  1) 📁 查看文件日志 (所有类别)"
    echo "  2) 📄 查看系统日志"
    echo "  3) 📄 查看文件操作日志"
    echo "  4) 🌐 查看 WebDAV 日志"
    echo "  5) 💾 查看缓存日志"
    echo "  6) 🗄️  查看数据库日志"
    echo ""
    echo "  7) 🔴 实时监控 - Xcode 运行日志 (推荐)"
    echo "  8) 🔴 实时监控 - 所有文件日志"
    echo "  9) 🔴 实时监控 - 文件操作日志"
    echo ""
    echo "  10) 🔍 搜索错误日志"
    echo "  11) 📊 查看日志统计"
    echo "  12) 🗑️  清理旧日志"
    echo ""
    echo "  0) 退出"
    echo ""
    echo -n "请输入选项 [0-12]: "
}

# 查看文件日志
view_file_logs() {
    local category=$1
    local pattern="*.log"
    
    if [ -n "$category" ]; then
        pattern="${category}-*.log"
    fi
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}📄 查看日志: $pattern${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    local files=$(ls -t "$LOG_DIR"/$pattern 2>/dev/null)
    
    if [ -z "$files" ]; then
        echo -e "${YELLOW}⚠️  没有找到日志文件${NC}"
        return
    fi
    
    for file in $files; do
        echo -e "${GREEN}📁 $file${NC}"
        echo ""
        tail -n 50 "$file" | while IFS= read -r line; do
            # 根据日志级别着色
            if [[ $line == *"ERROR"* ]]; then
                echo -e "${RED}$line${NC}"
            elif [[ $line == *"WARNING"* ]]; then
                echo -e "${YELLOW}$line${NC}"
            elif [[ $line == *"SUCCESS"* ]]; then
                echo -e "${GREEN}$line${NC}"
            elif [[ $line == *"DEBUG"* ]]; then
                echo -e "${PURPLE}$line${NC}"
            else
                echo "$line"
            fi
        done
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
    done
}

# 实时监控系统日志（Xcode 运行时）
monitor_system_logs() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}🔴 实时监控 CloudDrive 系统日志${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${YELLOW}提示: 这将显示 Xcode 运行时的所有日志${NC}"
    echo -e "${YELLOW}按 Ctrl+C 停止监控${NC}"
    echo ""
    
    # 使用 log stream 监控系统日志
    log stream --predicate 'subsystem == "net.aabg.CloudDrive"' --level debug --style compact 2>/dev/null | while IFS= read -r line; do
        # 根据内容着色
        if [[ $line == *"error"* ]] || [[ $line == *"ERROR"* ]]; then
            echo -e "${RED}$line${NC}"
        elif [[ $line == *"warning"* ]] || [[ $line == *"WARNING"* ]]; then
            echo -e "${YELLOW}$line${NC}"
        elif [[ $line == *"file-operations"* ]]; then
            echo -e "${BLUE}$line${NC}"
        elif [[ $line == *"webdav"* ]]; then
            echo -e "${CYAN}$line${NC}"
        else
            echo "$line"
        fi
    done
}

# 实时监控文件日志
monitor_file_logs() {
    local category=$1
    local pattern="*.log"
    
    if [ -n "$category" ]; then
        pattern="${category}-*.log"
    fi
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}🔴 实时监控文件日志: $pattern${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${YELLOW}按 Ctrl+C 停止监控${NC}"
    echo ""
    
    tail -f "$LOG_DIR"/$pattern 2>/dev/null | while IFS= read -r line; do
        if [[ $line == *"ERROR"* ]]; then
            echo -e "${RED}$line${NC}"
        elif [[ $line == *"WARNING"* ]]; then
            echo -e "${YELLOW}$line${NC}"
        elif [[ $line == *"SUCCESS"* ]]; then
            echo -e "${GREEN}$line${NC}"
        elif [[ $line == *"DEBUG"* ]]; then
            echo -e "${PURPLE}$line${NC}"
        else
            echo "$line"
        fi
    done
}

# 搜索错误日志
search_errors() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}🔍 搜索错误日志${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    if [ ! -d "$LOG_DIR" ]; then
        echo -e "${RED}❌ 日志目录不存在${NC}"
        return
    fi
    
    local errors=$(grep -r "ERROR" "$LOG_DIR"/*.log 2>/dev/null)
    
    if [ -z "$errors" ]; then
        echo -e "${GREEN}✅ 没有发现错误日志${NC}"
    else
        echo "$errors" | while IFS= read -r line; do
            echo -e "${RED}$line${NC}"
        done
    fi
    echo ""
}

# 查看日志统计
show_statistics() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}📊 日志统计信息${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    if [ ! -d "$LOG_DIR" ]; then
        echo -e "${RED}❌ 日志目录不存在${NC}"
        return
    fi
    
    echo -e "${BLUE}日志目录:${NC} $LOG_DIR"
    echo ""
    
    local total_files=$(ls "$LOG_DIR"/*.log 2>/dev/null | wc -l)
    local total_size=$(du -sh "$LOG_DIR" 2>/dev/null | cut -f1)
    
    echo -e "${BLUE}日志文件数量:${NC} $total_files"
    echo -e "${BLUE}总大小:${NC} $total_size"
    echo ""
    
    echo -e "${BLUE}各类日志统计:${NC}"
    for category in system file-operations webdav cache database; do
        local count=$(ls "$LOG_DIR"/${category}-*.log 2>/dev/null | wc -l)
        if [ $count -gt 0 ]; then
            local size=$(du -sh "$LOG_DIR"/${category}-*.log 2>/dev/null | tail -1 | cut -f1)
            echo -e "  ${GREEN}$category:${NC} $count 个文件, $size"
        fi
    done
    echo ""
    
    echo -e "${BLUE}日志级别统计:${NC}"
    for level in ERROR WARNING INFO DEBUG SUCCESS; do
        local count=$(grep -r "$level" "$LOG_DIR"/*.log 2>/dev/null | wc -l)
        if [ $count -gt 0 ]; then
            case $level in
                ERROR) echo -e "  ${RED}$level:${NC} $count" ;;
                WARNING) echo -e "  ${YELLOW}$level:${NC} $count" ;;
                SUCCESS) echo -e "  ${GREEN}$level:${NC} $count" ;;
                *) echo -e "  ${BLUE}$level:${NC} $count" ;;
            esac
        fi
    done
    echo ""
}

# 清理旧日志
cleanup_logs() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}🗑️  清理旧日志${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    if [ ! -d "$LOG_DIR" ]; then
        echo -e "${RED}❌ 日志目录不存在${NC}"
        return
    fi
    
    echo -e "${YELLOW}⚠️  这将删除所有旧日志文件${NC}"
    echo -n "确认清理? (y/N): "
    read -r confirm
    
    if [[ $confirm =~ ^[Yy]$ ]]; then
        rm -f "$LOG_DIR"/*.log
        echo -e "${GREEN}✅ 日志已清理${NC}"
    else
        echo -e "${BLUE}已取消${NC}"
    fi
    echo ""
}

# 主程序
main() {
    # 检查日志目录
    if ! check_log_dir; then
        exit 1
    fi
    
    while true; do
        show_menu
        read -r choice
        
        case $choice in
            1) view_file_logs "" ;;
            2) view_file_logs "system" ;;
            3) view_file_logs "file-operations" ;;
            4) view_file_logs "webdav" ;;
            5) view_file_logs "cache" ;;
            6) view_file_logs "database" ;;
            7) monitor_system_logs ;;
            8) monitor_file_logs "" ;;
            9) monitor_file_logs "file-operations" ;;
            10) search_errors ;;
            11) show_statistics ;;
            12) cleanup_logs ;;
            0) 
                echo ""
                echo -e "${GREEN}👋 再见！${NC}"
                echo ""
                exit 0
                ;;
            *)
                echo -e "${RED}❌ 无效选项${NC}"
                ;;
        esac
        
        if [ "$choice" != "7" ] && [ "$choice" != "8" ] && [ "$choice" != "9" ]; then
            echo ""
            echo -n "按回车键继续..."
            read -r
        fi
    done
}

# 运行主程序
main