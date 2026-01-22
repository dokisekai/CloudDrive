#!/bin/bash

# FileProvider 错误处理测试脚本
# 用于验证错误转换是否正确工作

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🧪 FileProvider 错误处理测试"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 检查是否有 CloudDrive 进程在运行
echo "📋 检查 CloudDrive 进程..."
if pgrep -x "CloudDrive" > /dev/null; then
    echo -e "${GREEN}✅ CloudDrive 正在运行${NC}"
else
    echo -e "${YELLOW}⚠️  CloudDrive 未运行，某些测试可能失败${NC}"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 监控 FileProvider 日志（10秒）"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 创建临时日志文件
LOG_FILE="/tmp/fileprovider_test_$(date +%s).log"

echo "📝 日志文件: $LOG_FILE"
echo ""

# 监控日志 10 秒
echo "⏱️  开始监控（10秒）..."
timeout 10 log stream --predicate 'subsystem == "com.apple.FileProvider" OR process == "CloudDriveFileProvider" OR process == "fileproviderd"' --level debug > "$LOG_FILE" 2>&1 &
LOG_PID=$!

# 等待日志收集
sleep 10

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 分析日志结果"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 检查关键错误
echo "1️⃣  检查不支持的错误域..."
UNSUPPORTED_ERRORS=$(grep -c "unsupported.*error.*domain\|CloudDriveCore.VFSError" "$LOG_FILE" 2>/dev/null || echo "0")
if [ "$UNSUPPORTED_ERRORS" -eq 0 ]; then
    echo -e "${GREEN}✅ 未发现不支持的错误域${NC}"
else
    echo -e "${RED}❌ 发现 $UNSUPPORTED_ERRORS 个不支持的错误域${NC}"
    echo "   详情："
    grep -i "unsupported.*error.*domain\|CloudDriveCore.VFSError" "$LOG_FILE" | head -3
fi

echo ""
echo "2️⃣  检查错误转换日志..."
CONVERSION_LOGS=$(grep -c "Converting VFSError to NSFileProviderError" "$LOG_FILE" 2>/dev/null || echo "0")
if [ "$CONVERSION_LOGS" -gt 0 ]; then
    echo -e "${GREEN}✅ 发现 $CONVERSION_LOGS 次错误转换（正常）${NC}"
    echo "   示例："
    grep "Converting VFSError to NSFileProviderError" "$LOG_FILE" | head -2
else
    echo -e "${YELLOW}⚠️  未发现错误转换日志（可能没有错误发生）${NC}"
fi

echo ""
echo "3️⃣  检查 CRIT 级别错误..."
CRIT_ERRORS=$(grep -c "\[CRIT\]" "$LOG_FILE" 2>/dev/null || echo "0")
if [ "$CRIT_ERRORS" -eq 0 ]; then
    echo -e "${GREEN}✅ 未发现 CRIT 级别错误${NC}"
else
    echo -e "${RED}❌ 发现 $CRIT_ERRORS 个 CRIT 级别错误${NC}"
    echo "   详情："
    grep "\[CRIT\]" "$LOG_FILE" | head -3
fi

echo ""
echo "4️⃣  检查 FileProvider 错误..."
FP_ERRORS=$(grep -c "FileProvider.*Error\|Failed to" "$LOG_FILE" 2>/dev/null || echo "0")
if [ "$FP_ERRORS" -eq 0 ]; then
    echo -e "${GREEN}✅ 未发现 FileProvider 错误${NC}"
else
    echo -e "${YELLOW}⚠️  发现 $FP_ERRORS 个 FileProvider 相关错误${NC}"
    echo "   最近的错误："
    grep -i "FileProvider.*Error\|Failed to" "$LOG_FILE" | tail -3
fi

echo ""
echo "5️⃣  检查 itemNotFound/fileNotFound 错误..."
NOT_FOUND_ERRORS=$(grep -c "itemNotFound\|fileNotFound" "$LOG_FILE" 2>/dev/null || echo "0")
if [ "$NOT_FOUND_ERRORS" -eq 0 ]; then
    echo -e "${GREEN}✅ 未发现 notFound 错误${NC}"
else
    echo -e "${BLUE}ℹ️  发现 $NOT_FOUND_ERRORS 个 notFound 错误（可能是正常的）${NC}"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📈 统计摘要"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

TOTAL_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
echo "📊 总日志行数: $TOTAL_LINES"
echo "🔴 不支持的错误域: $UNSUPPORTED_ERRORS"
echo "🔄 错误转换次数: $CONVERSION_LOGS"
echo "⚠️  CRIT 错误: $CRIT_ERRORS"
echo "❌ FileProvider 错误: $FP_ERRORS"
echo "🔍 NotFound 错误: $NOT_FOUND_ERRORS"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎯 测试结论"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 计算总分
SCORE=0
MAX_SCORE=3

if [ "$UNSUPPORTED_ERRORS" -eq 0 ]; then
    SCORE=$((SCORE + 1))
fi

if [ "$CRIT_ERRORS" -eq 0 ]; then
    SCORE=$((SCORE + 1))
fi

if [ "$FP_ERRORS" -lt 5 ]; then
    SCORE=$((SCORE + 1))
fi

if [ "$SCORE" -eq "$MAX_SCORE" ]; then
    echo -e "${GREEN}✅ 所有测试通过！错误处理修复成功！${NC}"
    echo ""
    echo "🎉 FileProvider 现在正确处理所有错误类型"
elif [ "$SCORE" -ge 2 ]; then
    echo -e "${YELLOW}⚠️  大部分测试通过，但仍有一些问题${NC}"
    echo ""
    echo "建议检查日志文件: $LOG_FILE"
else
    echo -e "${RED}❌ 测试失败，需要进一步调查${NC}"
    echo ""
    echo "请查看详细日志: $LOG_FILE"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📝 完整日志已保存到: $LOG_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 提供查看日志的命令
echo "💡 提示："
echo "   查看完整日志: cat $LOG_FILE"
echo "   搜索错误: grep -i error $LOG_FILE"
echo "   实时监控: log stream --predicate 'subsystem == \"com.apple.FileProvider\"' --level debug"
echo ""