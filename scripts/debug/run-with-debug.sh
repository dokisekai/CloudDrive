#!/bin/bash

# CloudDrive 调试脚本
# 用于收集所有相关的调试信息和日志

echo "🔍 CloudDrive 调试信息收集脚本"
echo "=================================="
echo "开始时间: $(date)"
echo ""

# 创建调试报告目录
DEBUG_DIR="$HOME/Desktop/CloudDrive-Debug-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DEBUG_DIR"
cd "$DEBUG_DIR"

echo "📁 调试报告目录: $DEBUG_DIR"
echo ""

# 1. 收集系统信息
echo "1️⃣ 收集系统信息..."
echo "=== 系统信息 ===" > system-info.txt
echo "时间: $(date)" >> system-info.txt
echo "系统: $(uname -a)" >> system-info.txt
echo "用户: $(whoami)" >> system-info.txt
echo "" >> system-info.txt

# 2. 检查进程状态
echo "2️⃣ 检查CloudDrive进程状态..."
echo "=== 进程状态 ===" >> system-info.txt
ps aux | grep -E "(CloudDrive|FileProvider)" | grep -v grep >> system-info.txt
echo "" >> system-info.txt

# 3. 检查挂载点
echo "3️⃣ 检查文件系统挂载点..."
echo "=== 挂载点信息 ===" >> system-info.txt
mount | grep -i clouddrive >> system-info.txt
ls -la "/Users/$(whoami)/Library/CloudStorage/" >> system-info.txt
echo "" >> system-info.txt

# 4. 复制所有日志文件
echo "4️⃣ 复制日志文件..."
LOG_DIR="/Users/$(whoami)/Library/Group Containers/group.net.aabg.CloudDrive/.CloudDrive/Logs"
if [ -d "$LOG_DIR" ]; then
    cp "$LOG_DIR"/*.log . 2>/dev/null
    echo "✅ 日志文件已复制"
    ls -la *.log
else
    echo "❌ 日志目录不存在: $LOG_DIR"
fi
echo ""

# 5. 分析错误和警告
echo "5️⃣ 分析错误和警告..."
echo "=== 错误分析 ===" > error-analysis.txt
echo "搜索时间: $(date)" >> error-analysis.txt
echo "" >> error-analysis.txt

if ls *.log >/dev/null 2>&1; then
    echo "--- HTTP 错误 ---" >> error-analysis.txt
    grep -h "40[0-9]\|50[0-9]" *.log >> error-analysis.txt 2>/dev/null
    echo "" >> error-analysis.txt
    
    echo "--- 一般错误 ---" >> error-analysis.txt
    grep -h -i "error\|错误\|失败\|failed" *.log >> error-analysis.txt 2>/dev/null
    echo "" >> error-analysis.txt
    
    echo "--- 警告信息 ---" >> error-analysis.txt
    grep -h -i "warning\|warn\|警告" *.log >> error-analysis.txt 2>/dev/null
    echo "" >> error-analysis.txt
    
    echo "--- 最近的重要事件 ---" >> error-analysis.txt
    grep -h "SUCCESS\|ERROR\|创建\|删除\|上传\|下载" *.log | tail -50 >> error-analysis.txt 2>/dev/null
else
    echo "没有找到日志文件" >> error-analysis.txt
fi

# 6. 检查配置文件
echo "6️⃣ 检查配置文件..."
CONFIG_DIR="/Users/$(whoami)/Library/Group Containers/group.net.aabg.CloudDrive/.CloudDrive"
if [ -d "$CONFIG_DIR" ]; then
    echo "=== 配置信息 ===" > config-info.txt
    echo "配置目录: $CONFIG_DIR" >> config-info.txt
    ls -la "$CONFIG_DIR" >> config-info.txt
    echo "" >> config-info.txt
    
    if [ -f "$CONFIG_DIR/sync_metadata.json" ]; then
        echo "--- 同步元数据 ---" >> config-info.txt
        cat "$CONFIG_DIR/sync_metadata.json" >> config-info.txt
        echo "" >> config-info.txt
    fi
    
    echo "✅ 配置信息已收集"
else
    echo "❌ 配置目录不存在: $CONFIG_DIR"
fi
echo ""

# 7. 检查数据库状态
echo "7️⃣ 检查VFS数据库..."
if [ -f "$CONFIG_DIR/vfs.db" ]; then
    echo "=== 数据库信息 ===" > database-info.txt
    echo "数据库文件: $CONFIG_DIR/vfs.db" >> database-info.txt
    ls -la "$CONFIG_DIR/vfs.db" >> database-info.txt
    echo "文件大小: $(stat -f%z "$CONFIG_DIR/vfs.db" 2>/dev/null || echo "无法获取") 字节" >> database-info.txt
    echo "✅ 数据库信息已收集"
else
    echo "❌ VFS数据库不存在"
fi
echo ""

# 8. 生成总结报告
echo "8️⃣ 生成总结报告..."
cat > README.md << EOF
# CloudDrive 调试报告

**生成时间:** $(date)  
**报告目录:** $DEBUG_DIR

## 📋 文件清单

- \`system-info.txt\` - 系统和进程信息
- \`error-analysis.txt\` - 错误和警告分析
- \`config-info.txt\` - 配置文件信息
- \`database-info.txt\` - 数据库状态信息
- \`*.log\` - 应用程序日志文件

## 🔍 快速诊断

### 检查要点：
1. **进程状态** - CloudDrive和FileProvider是否正在运行
2. **日志错误** - 查看error-analysis.txt中的错误信息
3. **WebDAV连接** - 检查网络请求的状态码
4. **路径问题** - 查看parentId和URL构建是否正确

### 常见问题：
- **404错误** - 通常表示路径构建问题
- **401/403错误** - 认证问题
- **网络错误** - 连接问题

## 📊 使用方法

1. 查看 \`error-analysis.txt\` 了解最近的错误
2. 检查相应的日志文件获取详细信息
3. 根据错误类型采取相应的修复措施

## 🛠️ 下一步

如果发现问题，请：
1. 记录具体的错误信息
2. 检查对应的代码逻辑
3. 实施修复方案
4. 重新测试验证

EOF

echo "✅ 总结报告已生成"
echo ""

# 9. 显示结果
echo "🎯 调试信息收集完成！"
echo ""
echo "📁 报告位置: $DEBUG_DIR"
echo "📄 主要文件:"
ls -la "$DEBUG_DIR"
echo ""
echo "🔍 快速查看错误:"
if [ -f "$DEBUG_DIR/error-analysis.txt" ]; then
    echo "--- 最近的错误 ---"
    head -20 "$DEBUG_DIR/error-analysis.txt"
else
    echo "没有找到错误分析文件"
fi
echo ""
echo "✅ 请查看生成的文件来分析问题"