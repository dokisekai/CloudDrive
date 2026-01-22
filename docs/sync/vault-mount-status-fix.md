# 保险库挂载状态和删除功能修复

## 问题描述

1. **无法删除保险库**：用户无法通过滑动删除保险库
2. **缺少挂载状态显示**：界面上没有显示保险库是否已挂载

## 解决方案

### 1. 添加挂载状态字段

在 [`VaultInfo`](CloudDriveCore/VirtualFileSystem.swift:1264) 结构体中添加了 `isMounted` 字段：

```swift
public struct VaultInfo: Identifiable, Codable, Hashable {
    // ... 其他字段
    
    // 挂载状态（不持久化，运行时状态）
    public var isMounted: Bool = false
    
    // 自定义 Codable 实现，排除 isMounted
    enum CodingKeys: String, CodingKey {
        case id, name, storagePath, createdAt, webdavURL, webdavUsername
    }
}
```

**关键设计**：
- `isMounted` 是运行时状态，不会被持久化到磁盘
- 通过自定义 `Codable` 实现，确保该字段不会被编码/解码
- 每次应用启动时，所有保险库默认为未挂载状态

### 2. 更新 AppState 管理挂载状态

在 [`AppState`](CloudDrive/AppState.swift) 中添加了挂载状态管理：

#### 连接/创建保险库时自动挂载
```swift
func connectWebDAVStorage(...) async throws {
    // ... 创建保险库
    
    let vaultInfo = VaultInfo(
        // ...
        isMounted: true  // 创建后自动挂载
    )
    
    // 更新挂载状态
    if let index = vaults.firstIndex(where: { $0.id == vaultId }) {
        vaults[index].isMounted = true
        saveVaults()
    }
}
```

#### 锁定保险库时更新状态
```swift
func lockVault() {
    // 更新挂载状态
    if let currentVault = currentVault,
       let index = vaults.firstIndex(where: { $0.id == currentVault.id }) {
        vaults[index].isMounted = false
        saveVaults()
    }
    
    // ... 其他锁定逻辑
}
```

#### 添加卸载功能
```swift
func unmountVault(_ vault: VaultInfo) {
    print("📤 AppState: 卸载保险库: \(vault.name)")
    
    if let index = vaults.firstIndex(where: { $0.id == vault.id }) {
        vaults[index].isMounted = false
        saveVaults()
    }
    
    if currentVault?.id == vault.id {
        lockVault()
    }
}
```

#### 删除前检查挂载状态
```swift
func deleteVault(_ vault: VaultInfo) {
    // 检查是否已挂载
    if vault.isMounted {
        print("⚠️ AppState: 保险库已挂载，无法删除")
        return
    }
    
    vaults.removeAll { $0.id == vault.id }
    saveVaults()
}
```

### 3. 更新 UI 显示挂载状态

在 [`ContentView`](CloudDrive/ContentView.swift) 中更新了界面：

#### 显示挂载状态徽章
```swift
struct VaultRow: View {
    let vault: VaultInfo
    @ObservedObject var appState: AppState
    
    var body: some View {
        HStack {
            // 图标根据挂载状态变化
            Image(systemName: vault.isMounted ? 
                "externaldrive.fill.badge.checkmark" : 
                "externaldrive.fill")
                .foregroundColor(vault.isMounted ? .green : .blue)
            
            VStack(alignment: .leading) {
                HStack {
                    Text(vault.name)
                    
                    // 挂载状态标签
                    if vault.isMounted {
                        Text("已挂载")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .foregroundColor(.green)
                            .cornerRadius(4)
                    }
                }
                // ...
            }
        }
        .opacity(vault.isMounted ? 1.0 : 0.6)  // 未挂载时半透明
    }
}
```

#### 添加卸载按钮
```swift
if vault.isMounted {
    Button(action: {
        showingUnmountConfirmation = true
    }) {
        Label("卸载", systemImage: "eject")
    }
    .alert("确认卸载", isPresented: $showingUnmountConfirmation) {
        Button("取消", role: .cancel) { }
        Button("卸载", role: .destructive) {
            appState.unmountVault(vault)
        }
    } message: {
        Text("确定要卸载保险库 \"\(vault.name)\" 吗？")
    }
}
```

#### 删除前检查并提示
```swift
private func deleteVaults(at offsets: IndexSet) {
    for index in offsets {
        let vault = appState.vaults[index]
        
        // 检查是否已挂载
        if vault.isMounted {
            deleteWarningMessage = "保险库 \"\(vault.name)\" 当前已挂载，请先卸载后再删除。"
            showingDeleteWarning = true
            return
        }
        
        appState.deleteVault(vault)
    }
}
```

## 功能特性

### ✅ 已实现

1. **挂载状态显示**
   - 已挂载：绿色图标 + "已挂载" 标签
   - 未挂载：蓝色图标 + 半透明显示

2. **卸载功能**
   - 已挂载的保险库显示"卸载"按钮
   - 点击卸载时显示确认对话框
   - 卸载后自动更新状态

3. **删除保护**
   - 已挂载的保险库无法删除
   - 尝试删除时显示友好的警告提示
   - 必须先卸载才能删除

4. **状态持久化**
   - 挂载状态不会被持久化
   - 每次启动应用时，所有保险库默认未挂载
   - 连接/创建保险库时自动挂载

5. **UI 反馈**
   - 图标颜色变化（绿色=已挂载，蓝色=未挂载）
   - 状态标签显示
   - 未挂载时半透明显示
   - "在 Finder 中打开" 按钮在未挂载时禁用

## 用户体验流程

### 创建新保险库
1. 用户点击"创建保险库"
2. 填写信息并连接 WebDAV
3. 保险库自动挂载（显示绿色图标和"已挂载"标签）
4. 可以立即使用

### 卸载保险库
1. 点击已挂载保险库的"卸载"按钮
2. 确认卸载操作
3. 保险库变为未挂载状态（蓝色图标，半透明）
4. 现在可以删除该保险库

### 删除保险库
1. 如果保险库已挂载，滑动删除时会显示警告
2. 必须先卸载保险库
3. 卸载后才能成功删除

### 重新挂载
1. 未挂载的保险库可以通过解锁功能重新挂载
2. 挂载后恢复正常使用

## 技术细节

### 状态管理
- 使用 `@Published` 属性包装器自动触发 UI 更新
- 通过 `@ObservedObject` 在视图中观察状态变化
- 状态变化立即反映在界面上

### 数据持久化
- `isMounted` 字段不会被序列化
- 通过自定义 `CodingKeys` 枚举排除该字段
- 确保每次启动应用时状态一致

### 错误处理
- 删除已挂载保险库时显示友好提示
- 卸载操作有确认对话框
- 所有操作都有日志记录

## 测试建议

1. **创建保险库**
   - 验证创建后自动显示"已挂载"状态
   - 验证图标为绿色

2. **卸载保险库**
   - 点击"卸载"按钮
   - 确认对话框显示正确
   - 卸载后状态更新为未挂载

3. **删除保护**
   - 尝试删除已挂载的保险库
   - 验证警告对话框显示
   - 验证无法删除

4. **删除未挂载保险库**
   - 先卸载保险库
   - 滑动删除
   - 验证成功删除

5. **应用重启**
   - 重启应用
   - 验证所有保险库显示为未挂载状态
   - 重新连接后恢复挂载状态

## 编译状态

✅ **BUILD SUCCEEDED** - 所有修改已通过编译

## 相关文件

- [`CloudDriveCore/VirtualFileSystem.swift`](CloudDriveCore/VirtualFileSystem.swift) - VaultInfo 结构体定义
- [`CloudDrive/AppState.swift`](CloudDrive/AppState.swift) - 状态管理逻辑
- [`CloudDrive/ContentView.swift`](CloudDrive/ContentView.swift) - UI 显示和交互