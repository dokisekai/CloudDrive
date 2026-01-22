//
//  FileProviderExtension.swift
//  CloudDriveFileProvider
//
//  File Provider Extension 核心实现 - 修复版
//

import FileProvider
import UniformTypeIdentifiers
import CloudDriveCore

// 使用 NSObject 和协议，而不是继承
class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    
    private let vfs = VirtualFileSystem.shared
    private let cacheManager = CacheManager.shared
    private let sync = FileProviderSync.shared
    let domain: NSFileProviderDomain
    private var vaultInfo: VaultInfo?
    
    required init(domain: NSFileProviderDomain) {
        NSLog("🔧 FileProvider: Initializing extension for domain: \(domain.identifier.rawValue)")
        logInfo(.system, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        logInfo(.system, "FileProvider Extension 正在初始化")
        logInfo(.system, "域名: \(domain.identifier.rawValue)")
        logInfo(.system, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        self.domain = domain
        super.init()
        
        // 从 domain identifier 中提取保险库 ID
        let domainId = domain.identifier.rawValue
        if domainId.hasPrefix("vault-") {
            let vaultId = String(domainId.dropFirst(6))
            logInfo(.system, "🔍 提取保险库 ID: \(vaultId)")
            
            // 从共享文件中读取保险库信息
            logInfo(.system, "📖 从共享文件读取保险库配置...")
            
            guard let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "group.net.aabg.CloudDrive"
            ) else {
                logError(.system, "❌ 无法获取 App Group 容器 URL")
                return
            }
            
            let configURL = containerURL.appendingPathComponent("vault_config.json")
            logInfo(.system, "📁 配置文件路径: \(configURL.path)")
            
            // 检查文件是否存在
            if !FileManager.default.fileExists(atPath: configURL.path) {
                logError(.system, "❌ 配置文件不存在")
                logInfo(.system, "   容器路径: \(containerURL.path)")
                
                // 列出容器中的文件
                if let files = try? FileManager.default.contentsOfDirectory(atPath: containerURL.path) {
                    logInfo(.system, "   容器中的文件: \(files)")
                }
                return
            }
            
            logSuccess(.system, "✅ 配置文件存在")
            
            do {
                let data = try Data(contentsOf: configURL)
                logSuccess(.system, "✅ 读取到数据，大小: \(data.count) 字节")
                
                let vault = try JSONDecoder().decode(VaultInfo.self, from: data)
                logSuccess(.system, "✅ 解码成功")
                
                // 验证 ID 是否匹配
                if vault.id == vaultId {
                    self.vaultInfo = vault
                    logSuccess(.system, "✅ 找到保险库信息: \(vault.name)")
                    
                    // 配置并加载保险库
                    configureAndLoadVault(vault)
                } else {
                    logError(.system, "❌ 保险库 ID 不匹配")
                    logInfo(.system, "   期望: \(vaultId)")
                    logInfo(.system, "   实际: \(vault.id)")
                }
            } catch {
                logError(.system, "❌ 读取或解码配置文件失败: \(error)")
            }
        }
        
        logSuccess(.system, "✅ Extension 初始化成功")
    }
    
    private func configureAndLoadVault(_ vault: VaultInfo) {
        logInfo(.system, "⚙️ 配置和加载保险库: \(vault.name)")
        
        // 配置存储
        if let webdavURL = vault.webdavURL,
           let webdavUsername = vault.webdavUsername,
           let url = URL(string: webdavURL) {
            
            logInfo(.webdav, "🔧 配置 WebDAV 存储")
            logInfo(.webdav, "   URL: \(webdavURL)")
            logInfo(.webdav, "   用户名: \(webdavUsername)")
            
            // 从 Keychain 获取密码
            if let password = getWebDAVPassword(for: vault.id) {
                logSuccess(.webdav, "🔑 从 Keychain 获取到密码")
                vfs.configureWebDAV(baseURL: url, username: webdavUsername, password: password)
                logSuccess(.webdav, "✅ WebDAV 配置完成")
                
                // 配置 SyncManager
                let webdavClient = WebDAVClient.shared
                let storageClient = WebDAVStorageAdapter(webDAVClient: webdavClient)
                SyncManager.shared.configure(storageClient: storageClient)
                logSuccess(.sync, "✅ SyncManager 已配置")
                
                // 设置当前保险库 ID
                Task {
                    do {
                        try await vfs.initializeDirectMappingVault(vaultId: vault.id, storagePath: "/")
                        logSuccess(.system, "✅ 保险库初始化完成")
                        
                        // 启动同步队列处理
                        SyncManager.shared.processSyncQueue()
                        logSuccess(.sync, "✅ 同步队列处理已启动")
                    } catch {
                        logError(.system, "❌ 保险库初始化失败: \(error)")
                    }
                }
            } else {
                logWarning(.webdav, "⚠️ 无法从 Keychain 获取密码")
            }
        }
    }
    
    private func getWebDAVPassword(for vaultId: String) -> String? {
        // 从共享 Keychain 获取密码
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "webdav-password-\(vaultId)",
            kSecAttrService as String: "net.aabg.CloudDrive",
            kSecReturnData as String: true,
            kSecAttrAccessGroup as String: "group.net.aabg.CloudDrive"
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess,
           let data = result as? Data,
           let password = String(data: data, encoding: .utf8) {
            return password
        }
        
        return nil
    }
    
    // MARK: - NSFileProviderReplicatedExtension 必需方法（不使用 override）
    func invalidate() {
        logInfo(.system, "🔄 FileProvider: Extension 无效化")
        
        // 清理资源，避免初始化失败后被重用
        self.vaultInfo = nil
        
        // 重置 VFS 状态
        VirtualFileSystem.shared.lock()
        
        // 清理缓存
        try? cacheManager.clearAllCache()
        
        logSuccess(.system, "✅ FileProvider: 资源清理完成")
    }
    
    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        logInfo(.fileOps, "📁 FileProvider: 请求项目标识符: \(identifier.rawValue)")
        let progress = Progress(totalUnitCount: 1)
        
        Task { [weak self] in
            guard let self = self else {
                logWarning(.fileOps, "⚠️ FileProvider: Self 为空，中止项目请求")
                completionHandler(nil, NSFileProviderError(.noSuchItem))
                progress.completedUnitCount = 1
                return
            }
            
            do {
                // 根目录 - 直接返回，不依赖 VFS
                if identifier == .rootContainer {
                    logInfo(.fileOps, "📁 FileProvider: 返回根容器项目")
                    let item = FileProviderItem(
                        identifier: .rootContainer,
                        parentIdentifier: .rootContainer,
                        filename: "CloudDrive",
                        contentType: .folder,
                        capabilities: [.allowsReading, .allowsAddingSubItems, .allowsContentEnumerating],
                        documentSize: nil,
                        contentModificationDate: Date(),
                        creationDate: Date()
                    )
                    completionHandler(item, nil)
                    progress.completedUnitCount = 1
                    return
                }
                
                // 从 VFS 获取文件信息
                logInfo(.fileOps, "🔍 FileProvider: 查找 ID 为 \(identifier.rawValue) 的项目")
                let vfsItem = try self.findItem(identifier: identifier.rawValue)
                let item = FileProviderItem(vfsItem: vfsItem)
                logSuccess(.fileOps, "✅ FileProvider: 找到项目: \(item.filename)")
                completionHandler(item, nil)
                progress.completedUnitCount = 1
                
            } catch let error as VFSError {
                logError(.fileOps, "❌ FileProvider: 获取项目 \(identifier.rawValue) 时发生 VFSError: \(error)")
                let fpError = convertVFSErrorToFileProviderError(error)
                completionHandler(nil, fpError)
                progress.completedUnitCount = 1
            } catch let error as NSFileProviderError {
                logError(.fileOps, "❌ FileProvider: 获取项目 \(identifier.rawValue) 时发生 NSFileProviderError: \(error)")
                completionHandler(nil, error)
                progress.completedUnitCount = 1
            } catch {
                logError(.fileOps, "❌ FileProvider: 获取项目 \(identifier.rawValue) 时发生未知错误: \(error)")
                completionHandler(nil, NSFileProviderError(.noSuchItem))
                progress.completedUnitCount = 1
            }
        }
        
        return progress
    }
    
    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                      version requestedVersion: NSFileProviderItemVersion?,
                      request: NSFileProviderRequest,
                      completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        
        logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        logInfo(.fileOps, "开始获取文件内容")
        logInfo(.fileOps, "Item ID: \(itemIdentifier.rawValue)")
        logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        let progress = Progress(totalUnitCount: 100)
        
        Task { [weak self] in
            guard let self = self else {
                logError(.fileOps, "获取文件内容失败: self is nil")
                completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
                return
            }
            
            do {
                let fileId = itemIdentifier.rawValue
                logInfo(.fileOps, "文件 ID: \(fileId)")
                
                let localURL = self.cacheManager.localPath(for: fileId)
                logInfo(.fileOps, "本地缓存路径: \(localURL.path)")
                
                // 检查缓存
                if self.cacheManager.isCached(fileId: fileId),
                   FileManager.default.fileExists(atPath: localURL.path) {
                    logSuccess(.cache, "缓存命中: \(fileId)")
                    
                    // 更新最后访问时间
                    self.cacheManager.updateLastAccessed(fileId: fileId)
                    
                    let vfsItem = try self.findItem(identifier: fileId)
                    let item = FileProviderItem(vfsItem: vfsItem)
                    
                    progress.completedUnitCount = 100
                    completionHandler(localURL, item, nil)
                    return
                }
                
                // 下载文件到临时位置
                logInfo(.fileOps, "缓存未命中，从远程下载")
                logInfo(.fileOps, "调用 vfs.downloadFile(fileId: \(fileId))")
                
                // 使用临时文件
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                
                try await self.vfs.downloadFile(fileId: fileId, to: tempURL)
                
                logSuccess(.fileOps, "下载完成到临时文件: \(tempURL.path)")
                
                // 移动到缓存并保存元数据
                logInfo(.fileOps, "移动到缓存...")
                try self.cacheManager.cacheFile(fileId: fileId, from: tempURL, policy: .automatic)
                
                progress.completedUnitCount = 100
                
                let vfsItem = try self.findItem(identifier: fileId)
                let item = FileProviderItem(vfsItem: vfsItem)
                
                logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                logSuccess(.fileOps, "文件获取成功")
                logInfo(.fileOps, "文件已缓存: \(localURL.path)")
                if let metadata = self.cacheManager.getCacheMetadata(fileId: fileId) {
                    logInfo(.cache, "缓存大小: \(metadata.size) 字节")
                    logInfo(.cache, "缓存策略: \(metadata.policy.rawValue)")
                }
                logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                completionHandler(localURL, item, nil)
                
            } catch let error as VFSError {
                logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                logError(.fileOps, "VFSError: \(error.localizedDescription)")
                logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                let fpError = convertVFSErrorToFileProviderError(error)
                progress.completedUnitCount = 100
                completionHandler(nil, nil, fpError)
            } catch let error as NSFileProviderError {
                logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                logError(.fileOps, "NSFileProviderError: \(error.localizedDescription)")
                logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                progress.completedUnitCount = 100
                completionHandler(nil, nil, error)
            } catch {
                logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                logError(.fileOps, "未知错误: \(error.localizedDescription)")
                logError(.fileOps, "错误类型: \(type(of: error))")
                logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                let fpError = NSFileProviderError(.serverUnreachable)
                progress.completedUnitCount = 100
                completionHandler(nil, nil, fpError)
            }
        }
        
        return progress
    }
    
    func createItem(basedOn itemTemplate: NSFileProviderItem,
                   fields: NSFileProviderItemFields,
                   contents url: URL?,
                   options: NSFileProviderCreateItemOptions = [],
                   request: NSFileProviderRequest,
                   completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
       
       logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
       logInfo(.fileOps, "📁 开始创建项目")
       logInfo(.fileOps, "项目名称: \(itemTemplate.filename)")
       logInfo(.fileOps, "项目类型: \(itemTemplate.contentType == .folder ? "目录" : "文件")")
       logInfo(.fileOps, "父项目ID: \(itemTemplate.parentItemIdentifier.rawValue)")
       logInfo(.fileOps, "选项: \(options)")
       logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
       
       let progress = Progress(totalUnitCount: 100)
       
       Task { [weak self] in
           guard let self = self else {
               logError(.fileOps, "创建项目失败: self 为空")
               completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
               return
           }
           
           do {
               let parentId = itemTemplate.parentItemIdentifier.rawValue
               let actualParentId: String
               if parentId == NSFileProviderItemIdentifier.rootContainer.rawValue {
                   actualParentId = "ROOT"
               } else {
                   // 确保子目录ID是完整路径格式（以/开头）
                   actualParentId = parentId.hasPrefix("/") ? parentId : "/\(parentId)"
               }
               
               logInfo(.fileOps, "📁 FileProvider.createItem: 开始创建项目")
               logInfo(.fileOps, "   项目名称: \(itemTemplate.filename)")
               logInfo(.fileOps, "   项目类型: \(itemTemplate.contentType == .folder ? "目录" : "文件")")
               logInfo(.fileOps, "   原始父ID: \(parentId)")
               logInfo(.fileOps, "   实际父ID: \(actualParentId)")
               logInfo(.fileOps, "   根容器ID: \(NSFileProviderItemIdentifier.rootContainer.rawValue)")
               logInfo(.fileOps, "   是否为根目录: \(parentId == NSFileProviderItemIdentifier.rootContainer.rawValue)")
               
               logInfo(.fileOps, "🔍 路径验证:")
               logInfo(.fileOps, "   原始parentId: '\(parentId)'")
               logInfo(.fileOps, "   处理后parentId: '\(actualParentId)'")
               logInfo(.fileOps, "   是否为根目录: \(actualParentId == "ROOT")")
               logInfo(.fileOps, "   路径格式检查: \(actualParentId.hasPrefix("/") || actualParentId == "ROOT" ? "✅" : "❌")")
               
               if itemTemplate.contentType == .folder {
                   logInfo(.fileOps, "📁 FileProvider: 创建目录操作")
                   logInfo(.fileOps, "   调用: vfs.createDirectory(name: \(itemTemplate.filename), parentId: \(actualParentId))")
                   
                   let vfsItem = try await self.vfs.createDirectory(
                       name: itemTemplate.filename,
                       parentId: actualParentId
                   )
                   
                   logSuccess(.fileOps, "✅ FileProvider: VFS创建目录成功")
                   logInfo(.fileOps, "   返回的VFS项目ID: \(vfsItem.id)")
                   logInfo(.fileOps, "   返回的VFS项目名称: \(vfsItem.name)")
                   
                   progress.completedUnitCount = 100
                   
                   let item = FileProviderItem(vfsItem: vfsItem)
                   
                   // 通知主应用文件已变化
                   if let vaultId = self.vaultInfo?.id {
                       logInfo(.sync, "📤 发送目录创建通知 - 保险库: \(vaultId), 目录: \(vfsItem.id)")
                       self.sync.notifyFileChanged(vaultId: vaultId, fileId: vfsItem.id)
                       logSuccess(.sync, "✅ 目录创建通知发送完成")
                   } else {
                       logWarning(.sync, "⚠️ 无保险库信息，无法发送通知")
                   }
                   
                   logSuccess(.fileOps, "✅ 目录创建完成: \(itemTemplate.filename)")
                   completionHandler(item, [], false, nil)
                   
               } else if let url = url {
                   logInfo(.fileOps, "📄 FileProvider: 创建文件操作")
                   logInfo(.fileOps, "   文件名: \(itemTemplate.filename)")
                   logInfo(.fileOps, "   源路径: \(url.path)")
                   let fileSize = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
                   logInfo(.fileOps, "   文件大小: \(fileSize ?? 0) 字节")
                   logInfo(.fileOps, "   调用: vfs.uploadFile(localURL: \(url.path), name: \(itemTemplate.filename), parentId: \(actualParentId))")
                   
                   do {
                       let vfsItem = try await self.vfs.uploadFile(
                           localURL: url,
                           name: itemTemplate.filename,
                           parentId: actualParentId
                       )
                       
                       logSuccess(.fileOps, "✅ FileProvider: VFS上传文件成功")
                       logInfo(.fileOps, "   返回的VFS项目ID: \(vfsItem.id)")
                       logInfo(.fileOps, "   返回的VFS项目名称: \(vfsItem.name)")
                       
                       progress.completedUnitCount = 100
                       
                       let item = FileProviderItem(vfsItem: vfsItem)
                       logSuccess(.fileOps, "上传完成, item ID: \(item.itemIdentifier.rawValue)")
                       
                       // 通知主应用文件已变化
                       if let vaultId = self.vaultInfo?.id {
                           logInfo(.sync, "📤 发送文件变更通知 - 保险库: \(vaultId), 文件: \(vfsItem.id)")
                           self.sync.notifyFileChanged(vaultId: vaultId, fileId: vfsItem.id)
                           logSuccess(.sync, "✅ 文件变更通知发送完成")
                       } else {
                           logWarning(.sync, "⚠️ 无保险库信息，无法发送通知")
                       }
                       
                       logSuccess(.fileOps, "✅ 文件创建完成: \(itemTemplate.filename)")
                       // Signal to system that upload is complete
                       completionHandler(item, [], false, nil)
                       
                   } catch {
                       // 上传失败，添加到同步队列以便稍后重试
                       logError(.fileOps, "上传失败，添加到同步队列: \(error.localizedDescription)")
                       
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
                       logInfo(.sync, "文件已添加到同步队列，将在网络恢复后自动上传")
                       
                       // 创建一个临时的 item，标记为待上传
                       let tempItem = FileProviderItem(
                           identifier: NSFileProviderItemIdentifier(fileId),
                           parentIdentifier: itemTemplate.parentItemIdentifier,
                           filename: itemTemplate.filename,
                           contentType: itemTemplate.contentType ?? .data,
                           capabilities: [.allowsReading, .allowsWriting, .allowsRenaming, .allowsDeleting],
                           documentSize: fileSize as Int64?,
                           contentModificationDate: Date(),
                           creationDate: Date()
                       )
                       
                       progress.completedUnitCount = 100
                       completionHandler(tempItem, [], false, nil)
                   }
                   
               } else {
                   throw NSFileProviderError(.noSuchItem)
               }
               
           } catch let error as VFSError {
               logError(.fileOps, "❌ FileProvider: createItem 中发生 VFSError: \(error)")
               let fpError = convertVFSErrorToFileProviderError(error)
               progress.completedUnitCount = 100
               completionHandler(nil, [], false, fpError)
           } catch let error as NSFileProviderError {
               logError(.fileOps, "❌ FileProvider: createItem 中发生 NSFileProviderError: \(error)")
               progress.completedUnitCount = 100
               completionHandler(nil, [], false, error)
           } catch {
               logError(.fileOps, "❌ FileProvider: createItem 中发生未知错误: \(error)")
               let fpError = NSFileProviderError(.cannotSynchronize)
               progress.completedUnitCount = 100
               completionHandler(nil, [], false, fpError)
           }
       }
       
       return progress
   }
    
    func modifyItem(_ item: NSFileProviderItem,
                   baseVersion version: NSFileProviderItemVersion,
                   changedFields: NSFileProviderItemFields,
                   contents newContents: URL?,
                   options: NSFileProviderModifyItemOptions = [],
                   request: NSFileProviderRequest,
                   completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
       
       logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
       logInfo(.fileOps, "📁 开始修改项目")
       logInfo(.fileOps, "项目名称: \(item.filename)")
       logInfo(.fileOps, "项目ID: \(item.itemIdentifier.rawValue)")
       logInfo(.fileOps, "更改字段: \(changedFields)")
       logInfo(.fileOps, "选项: \(options)")
       logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
       
       let progress = Progress(totalUnitCount: 100)
       
       Task { [weak self] in
           guard let self = self else {
               logError(.fileOps, "修改项目失败: self 为空")
               completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
               return
           }
           
           do {
               if let newContents = newContents {
                   logInfo(.fileOps, "📄 修改文件: \(item.filename)")
                   let fileId = item.itemIdentifier.rawValue
                   let parentId = item.parentItemIdentifier.rawValue
                   let actualParentId: String
                   if parentId == NSFileProviderItemIdentifier.rootContainer.rawValue {
                       actualParentId = "ROOT"
                   } else {
                       // 确保子目录ID是完整路径格式（以/开头），防止重复斜杠
                       actualParentId = parentId.hasPrefix("/") ? parentId : "/\(parentId)"
                   }
                   
                   logInfo(.fileOps, "准备覆盖文件 \(fileId)")
                   try await self.vfs.delete(itemId: fileId)
                   
                   let vfsItem = try await self.vfs.uploadFile(
                       localURL: newContents,
                       name: item.filename,
                       parentId: actualParentId
                   )
                   
                   progress.completedUnitCount = 100
                   
                   let newItem = FileProviderItem(vfsItem: vfsItem)
                   
                   // 通知主应用文件已变化
                   if let vaultId = self.vaultInfo?.id {
                       logInfo(.sync, "📤 发送文件修改通知 - 保险库: \(vaultId), 文件: \(vfsItem.id)")
                       self.sync.notifyFileChanged(vaultId: vaultId, fileId: vfsItem.id)
                       logSuccess(.sync, "✅ 文件修改通知发送完成")
                   } else {
                       logWarning(.sync, "⚠️ 无保险库信息，无法发送通知")
                   }
                   
                   logSuccess(.fileOps, "✅ 文件修改完成: \(item.filename)")
                   completionHandler(newItem, [], false, nil)
               } else {
                   logInfo(.fileOps, "仅元数据更改，无需更新内容")
                   progress.completedUnitCount = 100
                   completionHandler(item, [], false, nil)
               }
               
           } catch let error as VFSError {
               logError(.fileOps, "❌ FileProvider: modifyItem 中发生 VFSError: \(error)")
               let fpError = convertVFSErrorToFileProviderError(error)
               progress.completedUnitCount = 100
               completionHandler(nil, [], false, fpError)
           } catch let error as NSFileProviderError {
               logError(.fileOps, "❌ FileProvider: modifyItem 中发生 NSFileProviderError: \(error)")
               progress.completedUnitCount = 100
               completionHandler(nil, [], false, error)
           } catch {
               logError(.fileOps, "❌ FileProvider: modifyItem 中发生未知错误: \(error)")
               let fpError = NSFileProviderError(.cannotSynchronize)
               progress.completedUnitCount = 100
               completionHandler(nil, [], false, fpError)
           }
       }
       
       return progress
   }
    
    func deleteItem(identifier: NSFileProviderItemIdentifier,
                   baseVersion version: NSFileProviderItemVersion,
                   options: NSFileProviderDeleteItemOptions = [],
                   request: NSFileProviderRequest,
                   completionHandler: @escaping (Error?) -> Void) -> Progress {
       
       logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
       logInfo(.fileOps, "📁 开始删除项目")
       logInfo(.fileOps, "项目ID: \(identifier.rawValue)")
       logInfo(.fileOps, "基础版本: \(version)")
       logInfo(.fileOps, "选项: \(options)")
       logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
       
       let progress = Progress(totalUnitCount: 1)
       
       // 添加超时保护
       var hasCompleted = false
       let completionLock = NSLock()
       
       // 安全的 completion 包装器，确保只调用一次
       let safeCompletion: (Error?) -> Void = { error in
           completionLock.lock()
           defer { completionLock.unlock() }
           
           if !hasCompleted {
               hasCompleted = true
               progress.completedUnitCount = 1
               completionHandler(error)
           }
       }
       
       // 30秒超时保护
       DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
           completionLock.lock()
           let shouldTimeout = !hasCompleted
           completionLock.unlock()
           
           if shouldTimeout {
               logError(.fileOps, "⏰ 删除操作超时（30秒）")
               safeCompletion(NSFileProviderError(.serverUnreachable))
           }
       }
       
       Task { [weak self] in
           guard let self = self else {
               logError(.fileOps, "❌ 删除项目失败: self 为空")
               safeCompletion(NSFileProviderError(.noSuchItem))
               return
           }
           
           do {
               let fileId = identifier.rawValue
               logInfo(.fileOps, "准备删除文件: \(fileId)")
               
               // 检查是否为未下载的文件（仅云端文件）
               let isCached = self.cacheManager.isCached(fileId: fileId)
               logInfo(.fileOps, "文件缓存状态: \(isCached ? "已缓存" : "未缓存（仅云端）")")
               
               // 对于未下载的文件，直接删除云端文件，不进入回收站
               if !isCached {
                   logInfo(.fileOps, "未下载的文件，直接删除云端")
               }
               
               // 调用 VFS 删除（会删除云端文件）
               logInfo(.fileOps, "调用 VFS 删除: \(fileId)")
               
               // 直接调用删除操作（移除超时包装）
               try await self.vfs.delete(itemId: fileId)
               
               logSuccess(.fileOps, "✅ VFS 删除成功: \(fileId)")
               
               // 清理本地缓存（如果有）
               if isCached {
                   logInfo(.fileOps, "清理本地缓存文件: \(fileId)")
                   try? self.cacheManager.removeCachedFile(fileId: fileId)
                   logSuccess(.fileOps, "✅ 本地缓存清理完成")
               }
               
               // 通知主应用文件已变化
               if let vaultId = self.vaultInfo?.id {
                   logInfo(.sync, "📤 发送文件删除通知 - 保险库: \(vaultId), 文件: \(fileId)")
                   self.sync.notifyFileChanged(vaultId: vaultId, fileId: fileId)
                   logSuccess(.sync, "✅ 文件删除通知发送完成")
               } else {
                   logWarning(.sync, "⚠️ 无保险库信息，无法发送通知")
               }
               
               logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
               logSuccess(.fileOps, "✅ 项目删除成功: \(fileId)")
               logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
               safeCompletion(nil)
               
           } catch let error as VFSError {
               logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
               logError(.fileOps, "VFSError: \(error.localizedDescription)")
               logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
               logError(.fileOps, "❌ 删除项目失败: \(error.localizedDescription)")
               let fpError = convertVFSErrorToFileProviderError(error)
               safeCompletion(fpError)
           } catch let error as NSFileProviderError {
               logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
               logError(.fileOps, "NSFileProviderError: \(error.localizedDescription)")
               logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
               logError(.fileOps, "❌ 删除项目失败: \(error.localizedDescription)")
               safeCompletion(error)
           } catch {
               logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
               logError(.fileOps, "未知错误: \(error.localizedDescription)")
               logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
               logError(.fileOps, "❌ 删除项目失败: \(error.localizedDescription)")
               let fpError = NSFileProviderError(.serverUnreachable)
               safeCompletion(fpError)
           }
       }
       
       return progress
   }
    
    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                   request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        logInfo(.fileOps, "📁 FileProvider: 创建枚举器")
        logInfo(.fileOps, "容器项目ID: \(containerItemIdentifier.rawValue)")
        return FileProviderEnumerator(
            enumeratedItemIdentifier: containerItemIdentifier,
            vfs: vfs
        )
    }
    
    // MARK: - Helper Methods
    
    private func findItem(identifier: String, in directoryId: String = "ROOT") throws -> VirtualFileItem {
        do {
            let items = try vfs.listDirectory(directoryId: directoryId)
            
            if let item = items.first(where: { $0.id == identifier }) {
                return item
            }
            
            for item in items where item.isDirectory {
                if let found = try? findItem(identifier: identifier, in: item.id) {
                    return found
                }
            }
            
            throw NSFileProviderError(.noSuchItem)
        } catch let error as VFSError {
            // 转换 VFSError 为 NSFileProviderError
            throw convertVFSErrorToFileProviderError(error)
        } catch {
            // 其他错误也转换为 NSFileProviderError
            throw NSFileProviderError(.noSuchItem)
        }
    }
}

// MARK: - Error Conversion Helper

/// 将 VFSError 转换为 NSFileProviderError（确保不会泄露不支持的错误域）
fileprivate func convertVFSErrorToFileProviderError(_ vfsError: VFSError) -> NSFileProviderError {
    logInfo(.fileOps, "🔄 FileProvider: 转换 VFSError 为 NSFileProviderError")
    logError(.fileOps, "VFSError: \(vfsError)")
    
    switch vfsError {
    case .vaultLocked:
        logWarning(.fileOps, "Vault locked - returning notAuthenticated error")
        return NSFileProviderError(.notAuthenticated)
    case .parentNotFound:
        logWarning(.fileOps, "Parent not found - returning noSuchItem error")
        return NSFileProviderError(.noSuchItem)
    case .fileNotFound, .itemNotFound:
        logWarning(.fileOps, "File not found - returning noSuchItem error")
        return NSFileProviderError(.noSuchItem)
    case .encryptionFailed, .decryptionFailed:
        logError(.fileOps, "Encryption/Decryption failed - returning cannotSynchronize error")
        return NSFileProviderError(.cannotSynchronize)
    case .databaseError(let detail):
        logError(.database, "Database error: \(detail)")
        return NSFileProviderError(.serverUnreachable)
    case .invalidPath:
        logWarning(.fileOps, "Invalid path - returning noSuchItem error")
        return NSFileProviderError(.noSuchItem)
    case .networkError:
        logError(.webdav, "Network error - returning serverUnreachable error")
        return NSFileProviderError(.serverUnreachable)
    case .authenticationFailed:
        logError(.webdav, "Authentication failed - returning notAuthenticated error")
        return NSFileProviderError(.notAuthenticated)
    case .storageNotConfigured:
        logError(.fileOps, "Storage not configured - returning providerNotFound error")
        return NSFileProviderError(.providerNotFound)
    case .directoryCreationFailed(let detail):
        logError(.fileOps, "Directory creation failed: \(detail)")
        return NSFileProviderError(.cannotSynchronize)
    case .fileOperationFailed(let detail):
        logError(.fileOps, "File operation failed: \(detail)")
        return NSFileProviderError(.cannotSynchronize)
    @unknown default:
        logError(.fileOps, "Unknown VFSError case: \(vfsError)")
        return NSFileProviderError(.serverUnreachable)
    }
}

/// 通用错误转换函数（已弃用，使用 convertVFSErrorToFileProviderError）
fileprivate func convertToFileProviderError(_ error: Error) -> NSFileProviderError {
    // 如果已经是 NSFileProviderError，直接返回
    if let fpError = error as? NSFileProviderError {
        logInfo(.fileOps, "错误已是 NSFileProviderError 类型: \(fpError.code)")
        return fpError
    }
    
    // 转换 VFSError
    if let vfsError = error as? VFSError {
        logInfo(.fileOps, "转换 VFSError: \(vfsError)")
        return convertVFSErrorToFileProviderError(vfsError)
    }
    
    // 其他错误转换为通用错误
    logError(.fileOps, "转换未知错误类型: \(error)")
    return NSFileProviderError(.serverUnreachable)
}

// MARK: - File Provider Enumerator

class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    
    private let enumeratedItemIdentifier: NSFileProviderItemIdentifier
    private let vfs: VirtualFileSystem
    
    init(enumeratedItemIdentifier: NSFileProviderItemIdentifier, vfs: VirtualFileSystem) {
        logInfo(.fileOps, "📁 FileProviderEnumerator 初始化")
        logInfo(.fileOps, "枚举项目ID: \(enumeratedItemIdentifier.rawValue)")
        self.enumeratedItemIdentifier = enumeratedItemIdentifier
        self.vfs = vfs
        super.init()
    }
    
    func invalidate() {
        logInfo(.fileOps, "📁 FileProviderEnumerator 无效化")
        // 清理资源
    }
    
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        logInfo(.fileOps, "📁 开始枚举项目")
        logInfo(.fileOps, "项目ID: \(enumeratedItemIdentifier.rawValue)")
        logInfo(.fileOps, "页面: \(page)")
        logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        Task {
            do {
                let directoryId = enumeratedItemIdentifier == .rootContainer ? "ROOT" : enumeratedItemIdentifier.rawValue
                
                logInfo(.fileOps, "🔍 枚举目录: \(directoryId)")
                
                // 强制从云端获取最新数据，不使用任何缓存
                let vfsItems: [VirtualFileItem]
                do {
                    // 直接调用 VFS 的 WebDAV 获取方法，确保每次都是最新数据
                    logInfo(.webdav, "🔄 从云端获取最新文件列表...")
                    vfsItems = try await vfs.listDirectoryFromWebDAVAsync(directoryId: directoryId)
                    logSuccess(.webdav, "✅ 从云端获取到 \(vfsItems.count) 个最新项目")
                    for item in vfsItems {
                        logInfo(.fileOps, "   - \(item.isDirectory ? "📁" : "📄") \(item.name)")
                    }
                } catch {
                    logError(.webdav, "❌ 从云端获取文件列表失败: \(error)")
                    // 如果云端获取失败，尝试从本地数据库获取作为备选
                    do {
                        logInfo(.database, "⚠️ 云端获取失败，使用本地缓存数据")
                        vfsItems = try vfs.listDirectory(directoryId: directoryId)
                        logSuccess(.database, "✅ 使用本地缓存数据，共 \(vfsItems.count) 个项目")
                    } catch {
                        logError(.database, "❌ 本地数据库也获取失败，返回空列表: \(error)")
                        vfsItems = []
                    }
                }
                
                let items = vfsItems.map { FileProviderItem(vfsItem: $0) }
                logInfo(.fileOps, "📋 转换为 \(items.count) 个 FileProvider 项目")
                
                observer.didEnumerate(items)
                logSuccess(.fileOps, "✅ 枚举项目成功")
                
                observer.finishEnumerating(upTo: nil)
                logSuccess(.fileOps, "✅ 完成枚举")
                logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                
            } catch let error as VFSError {
                logError(.fileOps, "❌ VFSError during enumerateItems: \(error)")
                let fpError = convertVFSErrorToFileProviderError(error)
                observer.finishEnumeratingWithError(fpError)
            } catch let error as NSFileProviderError {
                logError(.fileOps, "❌ NSFileProviderError during enumerateItems: \(error)")
                observer.finishEnumeratingWithError(error)
            } catch {
                logError(.fileOps, "❌ Unknown error during enumerateItems: \(error)")
                let fpError = NSFileProviderError(.serverUnreachable)
                observer.finishEnumeratingWithError(fpError)
            }
        }
    }
    
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        logInfo(.fileOps, "📁 枚举更改")
        logInfo(.fileOps, "锚点: \(anchor)")
        observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(Date().timeIntervalSince1970.description.data(using: .utf8)!), moreComing: false)
    }
    
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        logInfo(.fileOps, "📁 获取当前同步锚点")
        let anchor = NSFileProviderSyncAnchor(Date().timeIntervalSince1970.description.data(using: .utf8)!)
        completionHandler(anchor)
    }
}
