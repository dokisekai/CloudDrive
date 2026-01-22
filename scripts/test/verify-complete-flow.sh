#!/bin/bash

echo "======================================"
echo "CloudDrive 完整流程验证"
echo "======================================"
echo ""

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 检查函数
check_pass() {
    echo -e "${GREEN}✅ $1${NC}"
}

check_fail() {
    echo -e "${RED}❌ $1${NC}"
}

check_warn() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

echo "1. 检查目录结构"
echo "-----------------------------------"

# 检查主目录
if [ -d ~/.CloudDrive ]; then
    check_pass "主目录存在: ~/.CloudDrive"
else
    check_fail "主目录不存在: ~/.CloudDrive"
    mkdir -p ~/.CloudDrive
    check_warn "已创建主目录"
fi

# 检查日志目录
if [ -d ~/.CloudDrive/Logs ]; then
    check_pass "日志目录存在"
    LOG_COUNT=$(ls ~/.CloudDrive/Logs/*.log 2>/dev/null | wc -l)
    if [ $LOG_COUNT -gt 0 ]; then
        check_pass "找到 $LOG_COUNT 个日志文件"
        ls -lh ~/.CloudDrive/Logs/*.log
    else
        check_warn "日志目录为空"
    fi
else
    check_fail "日志目录不存在"
fi

# 检查缓存目录
if [ -d ~/.CloudDrive/Cache ]; then
    check_pass "缓存目录存在"
    CACHE_SIZE=$(du -sh ~/.CloudDrive/Cache 2>/dev/null | cut -f1)
    check_pass "缓存大小: $CACHE_SIZE"
    
    # 检查元数据
    if [ -f ~/.CloudDrive/Cache/metadata.json ]; then
        check_pass "缓存元数据存在"
        CACHED_FILES=$(cat ~/.CloudDrive/Cache/metadata.json | grep -o '"fileId"' | wc -l)
        check_pass "已缓存文件数: $CACHED_FILES"
    else
        check_warn "缓存元数据不存在"
    fi
else
    check_warn "缓存目录不存在（首次运行正常）"
fi

# 检查数据库目录
if [ -d ~/.CloudDrive/Database ]; then
    check_pass "数据库目录存在"
    if [ -f ~/.CloudDrive/Database/vfs.db ]; then
        check_pass "数据库文件存在"
        DB_SIZE=$(ls -lh ~/.CloudDrive/Database/vfs.db | awk '{print $5}')
        check_pass "数据库大小: $DB_SIZE"
    else
        check_warn "数据库文件不存在"
    fi
else
    check_warn "数据库目录不存在（首次运行正常）"
fi

echo ""
echo "2. 检查应用进程"
echo "-----------------------------------"

# 检查主应用
if pgrep -x "CloudDrive" > /dev/null; then
    check_pass "主应用正在运行"
    ps aux | grep CloudDrive | grep -v grep | grep -v FileProvider
else
    check_fail "主应用未运行"
fi

# 检查 FileProvider 扩展
if pgrep -f "CloudDriveFileProvider" > /dev/null; then
    check_pass "FileProvider 扩展正在运行"
    ps aux | grep CloudDriveFileProvider | grep -v grep
else
    check_warn "FileProvider 扩展未运行"
fi

echo ""
echo "3. 检查日志内容"
echo "-----------------------------------"

if [ -d ~/.CloudDrive/Logs ]; then
    # 检查系统日志
    if [ -f ~/.CloudDrive/Logs/system-*.log ]; then
        SYSTEM_LOG=$(ls ~/.CloudDrive/Logs/system-*.log 2>/dev/null | head -1)
        if [ -f "$SYSTEM_LOG" ]; then
            check_pass "系统日志: $SYSTEM_LOG"
            echo "最后 5 行:"
            tail -5 "$SYSTEM_LOG"
        fi
    else
        check_warn "系统日志不存在"
    fi
    
    echo ""
    
    # 检查文件操作日志
    if [ -f ~/.CloudDrive/Logs/file-operations-*.log ]; then
        FILEOPS_LOG=$(ls ~/.CloudDrive/Logs/file-operations-*.log 2>/dev/null | head -1)
        if [ -f "$FILEOPS_LOG" ]; then
            check_pass "文件操作日志: $FILEOPS_LOG"
            echo "最后 5 行:"
            tail -5 "$FILEOPS_LOG"
        fi
    else
        check_warn "文件操作日志不存在"
    fi
fi

echo ""
echo "4. 检查 WebDAV 连接"
echo "-----------------------------------"

if [ -f ~/.CloudDrive/Logs/webdav-*.log ]; then
    WEBDAV_LOG=$(ls ~/.CloudDrive/Logs/webdav-*.log 2>/dev/null | head -1)
    if [ -f "$WEBDAV_LOG" ]; then
        check_pass "WebDAV 日志存在"
        
        # 检查连接成功
        if grep -q "连接成功" "$WEBDAV_LOG"; then
            check_pass "WebDAV 连接成功"
        else
            check_warn "未找到连接成功记录"
        fi
        
        # 检查下载记录
        DOWNLOAD_COUNT=$(grep -c "开始下载文件" "$WEBDAV_LOG" 2>/dev/null || echo "0")
        if [ $DOWNLOAD_COUNT -gt 0 ]; then
            check_pass "下载记录: $DOWNLOAD_COUNT 次"
        else
            check_warn "未找到下载记录"
        fi
    fi
else
    check_warn "WebDAV 日志不存在"
fi

echo ""
echo "5. 检查缓存功能"
echo "-----------------------------------"

if [ -f ~/.CloudDrive/Logs/cache-*.log ]; then
    CACHE_LOG=$(ls ~/.CloudDrive/Logs/cache-*.log 2>/dev/null | head -1)
    if [ -f "$CACHE_LOG" ]; then
        check_pass "缓存日志存在"
        
        # 检查缓存命中
        HIT_COUNT=$(grep -c "缓存命中" "$CACHE_LOG" 2>/dev/null || echo "0")
        if [ $HIT_COUNT -gt 0 ]; then
            check_pass "缓存命中: $HIT_COUNT 次"
        else
            check_warn "未找到缓存命中记录"
        fi
        
        # 检查文件缓存
        CACHED_COUNT=$(grep -c "文件已缓存" "$CACHE_LOG" 2>/dev/null || echo "0")
        if [ $CACHED_COUNT -gt 0 ]; then
            check_pass "文件缓存: $CACHED_COUNT 次"
        else
            check_warn "未找到文件缓存记录"
        fi
    fi
else
    check_warn "缓存日志不存在"
fi

echo ""
echo "6. 检查数据库"
echo "-----------------------------------"

if [ -f ~/.CloudDrive/Database/vfs.db ]; then
    check_pass "数据库文件存在"
    
    # 使用 sqlite3 检查表
    if command -v sqlite3 &> /dev/null; then
        TABLES=$(sqlite3 ~/.CloudDrive/Database/vfs.db ".tables" 2>/dev/null)
        if [ ! -z "$TABLES" ]; then
            check_pass "数据库表: $TABLES"
            
            # 检查文件数量
            FILE_COUNT=$(sqlite3 ~/.CloudDrive/Database/vfs.db "SELECT COUNT(*) FROM files;" 2>/dev/null || echo "0")
            check_pass "数据库中文件数: $FILE_COUNT"
        else
            check_warn "数据库表为空"
        fi
    else
        check_warn "sqlite3 未安装，无法检查数据库内容"
    fi
else
    check_warn "数据库文件不存在"
fi

echo ""
echo "7. 总结"
echo "-----------------------------------"

# 计算通过的检查项
TOTAL_CHECKS=20
PASSED_CHECKS=0

[ -d ~/.CloudDrive ] && ((PASSED_CHECKS++))
[ -d ~/.CloudDrive/Logs ] && ((PASSED_CHECKS++))
[ $(ls ~/.CloudDrive/Logs/*.log 2>/dev/null | wc -l) -gt 0 ] && ((PASSED_CHECKS++))
pgrep -x "CloudDrive" > /dev/null && ((PASSED_CHECKS++))

echo "通过检查: $PASSED_CHECKS / $TOTAL_CHECKS"
echo ""

if [ $PASSED_CHECKS -ge 15 ]; then
    check_pass "系统状态良好"
elif [ $PASSED_CHECKS -ge 10 ]; then
    check_warn "系统部分功能正常"
else
    check_fail "系统需要检查"
fi

echo ""
echo "======================================"
echo "验证完成"
echo "======================================"