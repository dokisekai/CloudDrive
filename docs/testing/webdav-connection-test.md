# WebDAV 连接测试功能

## 概述

添加了 WebDAV 连接测试功能，在创建保险库之前先验证 WebDAV 服务器连接是否正常，避免创建失败。

## 功能特性

### 1. 连接测试方法

在 [`WebDAVClient.swift`](CloudDriveCore/WebDAVClient.swift:34) 中添加了 `testConnection()` 方法：

```swift
public func testConnection() async throws -> Bool
```

**功能：**
- 使用 PROPFIND 方法测试根目录访问
- 10秒超时设置
- 详细的状态码检查和错误处理
- 区分认证失败、服务器不存在等不同错误

**返回值：**
- `true`: 连接成功
- 抛出异常: 连接失败（包含具体错误信息）

**错误类型：**
- `401/403`: 认证失败（用户名或密码错误）
- `404`: 服务器地址不存在
- 其他状态码: 服务器错误

### 2. UI 集成

在 [`CreateVaultView.swift`](CloudDrive/CreateVaultView.swift) 中添加了测试连接按钮：

**位置：** WebDAV 服务器配置区域下方

**功能：**
- 点击"测试连接"按钮验证 WebDAV 配置
- 显示测试进度（测试中...）
- 显示测试结果（连接成功 ✓ 或连接失败）
- 只有测试成功后才能创建保险库

**状态指示：**
- 🔵 未测试: 显示网络图标
- 🟡 测试中: 显示进度指示器
- 🟢 成功: 显示绿色对勾
- 🔴 失败: 显示错误信息

### 3. AppState 集成

在 [`AppState.swift`](CloudDrive/AppState.swift:33) 中添加了测试方法：

```swift
func testWebDAVConnection(url: String, username: String, password: String) async throws -> Bool
```

可在应用的其他地方调用此方法进行连接测试。

## 使用流程

### 创建保险库时的流程

1. **填写 WebDAV 配置**
   - WebDAV URL（例如：`https://webdav.123pan.cn/webdav`）
   - 用户名
   - 密码

2. **测试连接**
   - 点击"测试连接"按钮
   - 等待测试结果（最多10秒）
   - 查看连接状态

3. **创建保险库**
   - 只有连接测试成功后，"创建"按钮才会启用
   - 填写保险库名称
   - 点击"创建"按钮

## 技术实现

### 连接测试原理

使用 WebDAV 的 PROPFIND 方法测试根目录：

```http
PROPFIND / HTTP/1.1
Host: webdav.example.com
Depth: 0
Authorization: Basic <base64-credentials>
```

### 状态码处理

| 状态码 | 含义 | 处理方式 |
|--------|------|----------|
| 200-299 | 成功 | 返回 true |
| 401 | 未授权 | 抛出认证失败异常 |
| 403 | 禁止访问 | 抛出认证失败异常 |
| 404 | 未找到 | 抛出服务器不存在异常 |
| 其他 | 服务器错误 | 抛出服务器错误异常 |

### 错误处理

所有错误都会：
1. 在控制台输出详细日志
2. 在 UI 上显示用户友好的错误信息
3. 阻止用户继续创建保险库

## 优势

1. **提前验证**: 在创建保险库前验证连接，避免创建失败
2. **用户友好**: 清晰的状态指示和错误提示
3. **安全性**: 不会在连接失败时创建任何目录或文件
4. **调试便利**: 详细的日志输出便于问题排查

## 示例

### 成功场景

```
🔍 WebDAV: 测试连接...
📡 WebDAV: 服务器地址: https://webdav.123pan.cn/webdav
📡 WebDAV: 响应状态码: 207
✅ WebDAV: 连接成功！
```

### 认证失败场景

```
🔍 WebDAV: 测试连接...
📡 WebDAV: 服务器地址: https://webdav.123pan.cn/webdav
📡 WebDAV: 响应状态码: 401
❌ WebDAV: 认证失败（状态码: 401）
```

### 服务器不存在场景

```
🔍 WebDAV: 测试连接...
📡 WebDAV: 服务器地址: https://invalid.example.com/webdav
📡 WebDAV: 响应状态码: 404
❌ WebDAV: 服务器地址不存在（404）
```

## 注意事项

1. **超时设置**: 连接测试有10秒超时限制
2. **网络要求**: 需要网络连接才能进行测试
3. **必须测试**: 创建保险库前必须先测试连接成功
4. **配置变更**: 修改 WebDAV 配置后需要重新测试

## 相关文件

- [`CloudDriveCore/WebDAVClient.swift`](CloudDriveCore/WebDAVClient.swift) - WebDAV 客户端实现
- [`CloudDrive/CreateVaultView.swift`](CloudDrive/CreateVaultView.swift) - 创建保险库界面
- [`CloudDrive/AppState.swift`](CloudDrive/AppState.swift) - 应用状态管理