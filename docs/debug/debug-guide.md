# CloudDrive 调试和日志分析指南

## 📋 目录结构和日志位置

### 1. 主要日志目录
```
/Users/snz/Library/Group Containers/group.net.aabg.CloudDrive/.CloudDrive/Logs/
├── system-2026-01-14.log          # 系统日志
├── file-operations-2026-01-14.log # 文件操作日志
├── webdav-2026-01-14.log          # WebDAV请求日志
├── cache-2026-01-14.log           # 缓存操作日志
├── sync-2026-01-14.log            # 同步操作日志
└── database-2026-01-14.log        # 数据库操作日志
```

### 2. 其他重要目录
```
/Users/snz/Library/Group Containers/group.net.aabg.CloudDrive/.CloudDrive/
├── Cache/                         # 文件缓存目录
├── vfs.db                        # VFS数据库
└── sync_metadata.json           # 同步元数据
```

## 🔍 如何查看和分析日志

### 方法1：实时监控日志（推荐）
```bash
# 监控文件操作日志
tail -f "/Users/snz/Library/Group Containers/group.net.aabg.CloudDrive/.CloudDrive/Logs/file-operations-2026-01-14.log"

# 监控WebDAV日志
tail -f "/Users/snz/Library/Group Containers/group.net.aabg.CloudDrive/.CloudDrive/Logs/webdav-2026-01-14.log"

# 监控所有日志
tail -f "/Users/snz/Library/Group Containers/group.net.aabg.CloudDrive/.CloudDrive/Logs/"*.log
```

### 方法2：查看最近的日志条目
```bash
# 查看最近50条文件操作日志
tail -50 "/Users/snz/Library/Group Containers/group.net.aabg.CloudDrive/.CloudDrive/Logs/file-operations-2026-01-14.log"

# 查看最近50条WebDAV日志
tail -50 "/Users/snz/Library/Group Containers/group.net.aabg.CloudDrive/.CloudDrive/Logs/webdav-2026-01-14.log"
```

### 方法3：搜索特定错误
```bash
# 搜索404错误
grep "404" "/Users/snz/Library/Group Containers/group.net.aabg.CloudDrive/.CloudDrive/Logs/"*.log

# 搜索错误信息
grep "ERROR\|❌" "/Users/snz/Library/Group Containers/group.net.aabg.CloudDrive/.CloudDrive/Logs/"*.log

# 搜索WebDAV失败
grep "失败\|failed\|error" "/Users/snz/Library/Group Containers/group.net.aabg.CloudDrive/.CloudDrive/Logs/webdav-2026-01-14.log"
```

## 🚨 WebDAV访问失败诊断

### 常见的WebDAV失败模式

#### 1. HTTP 404 错误 - 路径不存在
```
[时间戳] [❌ ERROR] WebDAV请求失败: 404 Not Found
[时间戳] [ℹ️ INFO] 请求URL: https://webdav.123pan.cn/webdav/错误的路径
```
**原因：** 请求的路径在服务器上不存在
**解决：** 检查路径构建逻辑

#### 2. HTTP 401/403 错误 - 认证失败
```
[时间戳] [❌ ERROR] WebDAV认证失败: 401 Unauthorized
```
**原因：** 用户名密码错误或过期
**解决：** 重新配置WebDAV凭据

#### 3. HTTP 500 错误 - 服务器内部错误
```
[时间戳] [❌ ERROR] WebDAV服务器错误: 500 Internal Server Error
```
**原因：** WebDAV服务器内部问题
**解决：** 检查服务器状态，稍后重试

#### 4. 网络连接错误
```
[时间戳] [❌ ERROR] 网络连接失败: The Internet connection appears to be offline
```
**原因：** 网络连接问题
**解决：** 检查网络连接

## 📊 日志分析示例

### 正常的文件创建流程
```
[时间戳] [ℹ️ INFO] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[时间戳] [ℹ️ INFO] 📁 FileProvider.createItem: 开始创建项目
[时间戳] [ℹ️ INFO]    项目名称: 测试文件夹
[时间戳] [ℹ️ INFO]    项目类型: 目录
[时间戳] [ℹ️ INFO]    原始父ID: /未命名文件夹
[时间戳] [ℹ️ INFO]    实际父ID: /未命名文件夹
[时间戳] [ℹ️ INFO] 📁 FileProvider: 创建目录操作
[时间戳] [ℹ️ INFO]    调用: vfs.createDirectory(name: 测试文件夹, parentId: /未命名文件夹)
[时间戳] [ℹ️ INFO] 创建目录: 测试文件夹
[时间戳] [ℹ️ INFO] 请求 URL: https://webdav.123pan.cn/webdav/%E6%9C%AA%E5%91%BD%E5%90%8D%E6%96%87%E4%BB%B6%E5%A4%B9/%E6%B5%8B%E8%AF%95%E6%96%87%E4%BB%B6%E5%A4%B9
[时间戳] [ℹ️ INFO] 响应状态码: 201
[时间戳] [✅ SUCCESS] 目录创建成功: 测试文件夹
[时间戳] [✅ SUCCESS] ✅ FileProvider: VFS创建目录成功
```

### 异常的文件创建流程（问题示例）
```
[时间戳] [ℹ️ INFO] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[时间戳] [ℹ️ INFO] 📁 FileProvider.createItem: 开始创建项目
[时间戳] [ℹ️ INFO]    项目名称: 测试文件夹
[时间戳] [ℹ️ INFO]    项目类型: 目录
[时间戳] [ℹ️ INFO]    原始父ID: 未命名文件夹  # ⚠️ 注意：缺少前导斜杠
[时间戳] [ℹ️ INFO]    实际父ID: 未命名文件夹  # ⚠️ 问题：不是完整路径
[时间戳] [ℹ️ INFO] 📁 FileProvider: 创建目录操作
[时间戳] [ℹ️ INFO]    调用: vfs.createDirectory(name: 测试文件夹, parentId: 未命名文件夹)
[时间戳] [❌ ERROR] WebDAV请求失败: 404 Not Found  # ⚠️ 失败
[时间戳] [ℹ️ INFO] 请求 URL: https://webdav.123pan.cn/webdav/未命名文件夹/测试文件夹  # ⚠️ 错误的URL
```

## 🛠️ 调试步骤

### 步骤1：确认应用程序运行状态
```bash
# 检查CloudDrive进程
ps aux | grep CloudDrive

# 检查FileProvider进程
ps aux | grep FileProvider
```

### 步骤2：清理并重启日志监控
```bash
# 停止现有的日志监控
pkill -f "tail -f"

# 开始新的日志监控
tail -f "/Users/snz/Library/Group Containers/group.net.aabg.CloudDrive/.CloudDrive/Logs/file-operations-2026-01-14.log"
```

### 步骤3：执行测试操作
1. 打开Finder
2. 导航到CloudDrive挂载点
3. 进入子目录（如"未命名文件夹"）
4. 创建新文件夹或文件
5. 观察日志输出

### 步骤4：分析日志输出
查找以下关键信息：
- **parentId的值** - 应该是完整路径
- **WebDAV请求URL** - 应该是正确编码的完整URL
- **HTTP响应状态码** - 201表示成功，404表示路径错误
- **错误信息** - 具体的失败原因

## 🔧 常见问题和解决方案

### 问题1：子目录操作不同步
**症状：** 在子目录中创建文件/文件夹，本地显示成功但云端没有
**日志特征：** 
```
[时间戳] [❌ ERROR] WebDAV请求失败: 404 Not Found
[时间戳] [ℹ️ INFO] 请求 URL: https://webdav.123pan.cn/webdav/错误路径
```
**解决方案：** 修复parentId到完整路径的转换逻辑

### 问题2：路径编码问题
**症状：** 中文文件名或路径访问失败
**日志特征：** URL中的中文字符编码不正确
**解决方案：** 检查URL编码逻辑

### 问题3：认证失败
**症状：** 所有WebDAV操作都失败
**日志特征：** 
```
[时间戳] [❌ ERROR] WebDAV认证失败: 401 Unauthorized
```
**解决方案：** 重新配置WebDAV凭据

## 📝 生成调试报告

### 收集所有相关日志
```bash
# 创建调试报告目录
mkdir -p ~/Desktop/CloudDrive-Debug-$(date +%Y%m%d-%H%M%S)
cd ~/Desktop/CloudDrive-Debug-$(date +%Y%m%d-%H%M%S)

# 复制所有日志文件
cp "/Users/snz/Library/Group Containers/group.net.aabg.CloudDrive/.CloudDrive/Logs/"*.log .

# 收集系统信息
echo "=== CloudDrive Debug Report ===" > debug-report.txt
echo "Generated: $(date)" >> debug-report.txt
echo "System: $(uname -a)" >> debug-report.txt
echo "" >> debug-report.txt

# 收集进程信息
echo "=== Running Processes ===" >> debug-report.txt
ps aux | grep -E "(CloudDrive|FileProvider)" >> debug-report.txt
echo "" >> debug-report.txt

# 收集最近的错误
echo "=== Recent Errors ===" >> debug-report.txt
grep -h "ERROR\|❌" *.log | tail -20 >> debug-report.txt
```

## 🎯 下一步行动

1. **立即执行：** 开始监控日志并执行测试操作
2. **收集数据：** 记录具体的parentId值和WebDAV URL
3. **分析问题：** 确定路径构建逻辑的具体问题
4. **实施修复：** 修改FileProvider的parentId处理逻辑
5. **验证修复：** 重新测试确保问题解决

---

**使用此指南：**
1. 首先运行日志监控命令
2. 在Finder中执行测试操作
3. 分析日志输出找到问题
4. 根据问题类型实施相应的修复方案

**需要帮助时：** 将相关的日志片段发送给我进行分析