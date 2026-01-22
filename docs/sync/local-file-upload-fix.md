# 本地文件上传问题修复方案

## 问题分析

经过代码审查，发现系统**已经实现了自动上传功能**，但存在以下潜在问题：

1. **网络故障时没有重试机制**
2. **SyncManager 在 FileProvider Extension 中未被正确使用**
3. **离线创建的文件不会排队等待上传**

## 修复方案

### 修复 1：在 FileProvider Extension 中添加失败重试机制

**问题**：当上传失败时，文件不会自动重试上传

**解决方案**：修改 `FileProviderExtension.swift` 的 `createItem` 方法，添加失败处理

#### 修改位置：`CloudDriveFileProvider/FileProviderExtension.swift`

在 `createItem` 方法中，当上传失败时，将文件添加到同步队列：

```swift
} else if let url = url {
    logInfo(.fileOps, "上传文件: \(itemTemplate.filename)")
    logInfo(.fileOps, "源路径: \(url.path)")
    
    do {
        let vfsItem = try await self.vfs.uploadFile(
            localURL: url,
            name: itemTemplate.filename,
            parentId: actualParentId
        )
        
        progress.completedUnitCount = 100
        let item = FileProviderItem(vfsItem: vfsItem)
        
        // 通知主应用文件已变化
        if let vaultId = self.vaultInfo?.id {
            self.sync.notifyFileChanged(vaultId: vaultId, fileId: vfsItem.id)
        }
        
        completionHandler(item, [], false, nil)
        
    } catch {
        // ✅ 新增：上传失败时添加到同步队列
        logError(.fileOps, "上传失败，添加到同步队列: \(error)")
        
        // 构建远程路径
        let remotePath: String
        if actualParentId == "ROOT" {
            remotePath = "/\(itemTemplate.filename)"
        } else if actualParentId.hasSuffix("/") {
            remotePath = "\(actualParentId)\(itemTemplate.filename)"
        } else {
            remotePath = "\(actualParentId)/\(itemTemplate.filename)"
        }
        
        // 添加到同步队列
        let fileId = remotePath
        SyncManager.shared.addToSyncQueue(.upload(
            fileId: fileId,
            localPath: url.path,
            remotePath: remotePath
        ))
        
        // 创建一个临时的 item，标记为待上传
        let tempItem = FileProviderItem(
            identifier: NSFileProviderItemIdentifier(fileId),
            parentIdentifier: itemTemplate.parentItemIdentifier,
            filename: itemTemplate.filename,
            contentType: itemTemplate.contentType ?? .data,
            capabilities: [.allowsReading, .allowsWriting, .allowsRenaming, .allowsDeleting],
            documentSize: nil,
            contentModificationDate: Date(),
            creationDate: Date()
        )
        
        progress.completedUnitCount = 100
        completionHandler(tempItem, [], false, nil)
    }
}
```

### 修复 2：确保 SyncManager 在 FileProvider Extension 中正确配置

**问题**：SyncManager 需要 StorageClient 才能处理同步队列，但在 FileProvider Extension 中可能未配置

**解决方案**：在 FileProvider Extension 初始化时配置 SyncManager

#### 修改位置：`CloudDriveFileProvider/FileProviderExtension.swift`

在 `configureAndLoadVault` 方法中添加 SyncManager 配置：

```swift
private func configureAndLoadVault(_ vault: VaultInfo) {
    NSLog("⚙️ FileProvider: Configuring and loading vault: \(vault.name)")
    
    if let webdavURL = vault.webdavURL,
       let webdavUsername = vault.webdavUsername,
       let url = URL(string: webdavURL) {
        
        NSLog("🔧 FileProvider: 配置 WebDAV 存储")
        
        if let password = getWebDAVPassword(for: vault.id) {
            NSLog("🔑 FileProvider: 从 Keychain 获取到密码")
            vfs.configureWebDAV(baseURL: url, username: webdavUsername, password: password)
            
            // ✅ 新增：配置 SyncManager
            let webdavClient = WebDAVClient.shared
            let storageClient = WebDAVStorageAdapter(webDAVClient: webdavClient)
            SyncManager.shared.configure(storageClient: storageClient)
            NSLog("✅ FileProvider: SyncManager 已配置")
            
            // 设置当前保险库 ID
            Task {
                do {
                    try await vfs.initializeDirectMappingVault(vaultId: vault.id, storagePath: "/")
                    NSLog("✅ FileProvider: 保险库初始化完成")
                    
                    // ✅ 新增：启动同步队列处理
                    SyncManager.shared.processSyncQueue()
                    NSLog("✅ FileProvider: 同步队列处理已启动")
                } catch {
                    NSLog("❌ FileProvider: 保险库初始化失败: \(error)")
                }
            }
        }
    }
}
```

### 修复 3：在主应用中也确保 SyncManager 配置

**问题**：主应用中创建保险库后，SyncManager 可能未配置

**解决方案**：在 `AppState.swift` 的 `connectWebDAVStorage` 方法中配置 SyncManager

#### 修改位置：`CloudDrive/AppState.swift`

在 `connectWebDAVStorage` 方法中添加：

```swift
// 配置 WebDAV
vfs.configureWebDAV(baseURL: url, username: username, password: webdavPassword)

// ✅ 新增：配置 SyncManager
let webdavClient = WebDAVClient.shared
let storageClient = WebDAVStorageAdapter(webDAVClient: webdavClient)
SyncManager.shared.configure(storageClient: storageClient)
print("✅ AppState: SyncManager 已配置")
```

### 修复 4：添加网络状态监听和自动重试

**问题**：网络恢复后不会自动处理待上传的文件

**解决方案**：SyncManager 已经实现了网络监听，但需要确保在网络恢复时触发

#### 验证位置：`CloudDriveCore/SyncManager.swift:75-94`

当前代码已经实现了网络监听：

```swift
private func startNetworkMonitoring() {
    networkMonitor.pathUpdateHandler = { [weak self] path in
        guard let self = self else { return }
        
        let newStatus: NetworkStatus = path.status == .satisfied ? .online : .offline
        
        if newStatus != self.networkStatus {
            self.networkStatus = newStatus
            logInfo(.sync, "网络状态变更: \(newStatus == .online ? "在线" : "离线")")
            
            // 如果网络恢复，处理同步队列
            if newStatus == .online {
                self.processSyncQueue()  // ✅ 已实现
            }
        }
    }
    
    let queue = DispatchQueue(label: "com.clouddrive.network.monitor")
    networkMonitor.start(queue: queue)
}
```

这个功能已经正确实现，无需修改。

## 实施步骤

### 步骤 1：修改 FileProviderExtension.swift

添加上传失败处理和 SyncManager 配置。

### 步骤 2：修改 AppState.swift

确保主应用中 SyncManager 正确配置。

### 步骤 3：测试验证

1. **正常上传测试**：
   - 在 Finder 中创建文件
   - 确认文件立即上传到 WebDAV

2. **离线上传测试**：
   - 断开网络
   - 在 Finder 中创建文件
   - 恢复网络
   - 确认文件自动上传

3. **失败重试测试**：
   - 模拟网络不稳定
   - 创建文件
   - 确认失败后自动重试

## 预期效果

修复后，系统将具备以下能力：

1. ✅ **自动上传**：文件创建后立即上传
2. ✅ **失败重试**：上传失败后添加到队列，自动重试
3. ✅ **离线队列**：离线时创建的文件在网络恢复后自动上传
4. ✅ **网络监听**：自动检测网络状态变化
5. ✅ **进度跟踪**：上传过程中显示进度

## 注意事项

1. **文件冲突**：如果同名文件已存在，WebDAV 会覆盖（这是当前行为）
2. **大文件上传**：大文件上传可能需要较长时间，建议添加超时处理
3. **并发上传**：多个文件同时创建时会并发上传，注意服务器负载

## 验证清单

- [ ] FileProvider Extension 中添加了失败处理
- [ ] SyncManager 在 FileProvider Extension 中正确配置
- [ ] SyncManager 在主应用中正确配置
- [ ] 网络监听正常工作
- [ ] 离线创建的文件能在网络恢复后上传
- [ ] 上传失败的文件能自动重试
- [ ] 日志正确记录所有操作