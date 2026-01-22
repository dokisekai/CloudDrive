#!/bin/bash

# 查看 FileProvider 相关日志的脚本

LOG_DIR="/Users/snz/Library/Group Containers/group.net.aabg.CloudDrive/.CloudDrive/Logs"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 FileProvider 日志查看器"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 检查日志目录是否存在
if [ ! -d "$LOG_DIR" ]; then
    echo "❌ 日志目录不存在: $LOG_DIR"
    exit 1
fi

echo "📁 日志目录: $LOG_DIR"
echo ""

# 显示可用的日志文件
echo "📄 可用的日志文件:"
ls -lh "$LOG_DIR"/*.log 2>/dev/null || echo "   没有找到日志文件"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📤 文件操作日志 (file-operations)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if ls "$LOG_DIR"/file-operations-*.log 1> /dev/null 2>&1; then
    tail -100 "$LOG_DIR"/file-operations-*.log | grep -E "(上传|下载|创建|删除|Upload|Download|Create|Delete)" || echo "   没有找到相关操作"
else
    echo "   ⚠️  没有文件操作日志"
fi
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔄 同步日志 (sync)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if ls "$LOG_DIR"/sync-*.log 1> /dev/null 2>&1; then
    tail -50 "$LOG_DIR"/sync-*.log
else
    echo "   ⚠️  没有同步日志"
fi
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🌐 WebDAV 日志 (webdav)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if ls "$LOG_DIR"/webdav-*.log 1> /dev/null 2>&1; then
    tail -50 "$LOG_DIR"/webdav-*.log
else
    echo "   ⚠️  没有 WebDAV 日志"
fi
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "💾 缓存日志 (cache)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if ls "$LOG_DIR"/cache-*.log 1> /dev/null 2>&1; then
    tail -30 "$LOG_DIR"/cache-*.log
else
    echo "   ⚠️  没有缓存日志"
fi
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 系统日志中的 FileProvider 相关信息"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "最近的 FileProvider 日志 (来自 Console.app):"
log show --predicate 'subsystem == "net.aabg.CloudDrive"' --last 5m --info --debug 2>/dev/null | tail -100 || echo "   无法访问系统日志"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 日志查看完成"
echo ""
echo "💡 提示:"
echo "   - 如果看不到 FileProvider 日志，可能是因为扩展还没有被触发"
echo "   - 尝试在 Finder 中打开虚拟盘并进行文件操作"
echo "   - 使用 'log stream --predicate \"subsystem == \\\"net.aabg.CloudDrive\\\"\"' 实时查看日志"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"