//
//  DirectoryThumbnailCatalogManager.swift
//  CloudDrivePreview
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  目录级单一清单包 (.thumbnails.catalog) 内存缓存与云端同步管理器
//

import Foundation
import CloudDriveContracts
import CloudDriveSupport

public final class DirectoryThumbnailCatalogManager: @unchecked Sendable {
    public static let shared = DirectoryThumbnailCatalogManager()
    
    private let lock = NSLock()
    private var memoryCatalogs: [String: ThumbnailCatalog] = [:] // key: directoryId
    private var lruOrder: [String] = []                           // LRU 淘汰链表
    private let maxMemoryCatalogs = 8                             // 限制常驻内存最多 8 个目录清单，防止 Jetsam OOM
    private let catalogsDiskDir: URL
    
    // 写入防抖任务表 (directoryId -> Task)
    private var pendingSaveTasks: [String: Task<Void, Never>] = [:]
    
    private init() {
        self.catalogsDiskDir = CloudDrivePaths.thumbnailsDirectory.appendingPathComponent("catalogs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: catalogsDiskDir.path) {
            try? FileManager.default.createDirectory(at: catalogsDiskDir, withIntermediateDirectories: true)
        }
    }
    
    // MARK: - LRU 内存淘汰管理
    
    private func touchLRU(directoryId: String) {
        lruOrder.removeAll { $0 == directoryId }
        lruOrder.append(directoryId)
        while lruOrder.count > maxMemoryCatalogs {
            let evictedId = lruOrder.removeFirst()
            memoryCatalogs.removeValue(forKey: evictedId)
        }
    }
    
    // MARK: - 本地磁盘缓存路径
    
    private func localCatalogURL(directoryId: String) -> URL {
        let safeId = directoryId.replacingOccurrences(of: "/", with: "_")
                                .replacingOccurrences(of: ":", with: "_")
        return catalogsDiskDir.appendingPathComponent("catalog_\(safeId).bin")
    }
    
    // MARK: - 查询缩略图 (优先从 Catalog 获取，支持时间戳失效比对)
    
    public func getThumbnailData(directoryId: String, fileId: String, minTimestamp: Int64? = nil) -> Data? {
        lock.lock()
        let catalog = memoryCatalogs[directoryId]
        if catalog != nil { touchLRU(directoryId: directoryId) }
        lock.unlock()
        
        guard let cat = catalog else { return nil }
        if let minTs = minTimestamp, minTs > 0 {
            if let entry = cat.getEntry(forFileId: fileId), entry.timestamp < minTs {
                return nil // 缩略图时间戳过旧，失效
            }
        }
        return cat.getImageData(forFileId: fileId)
    }
    
    public func getThumbnailData(directoryId: String, filename: String, minTimestamp: Int64? = nil) -> Data? {
        lock.lock()
        let catalog = memoryCatalogs[directoryId]
        if catalog != nil { touchLRU(directoryId: directoryId) }
        lock.unlock()
        
        guard let cat = catalog else { return nil }
        if let minTs = minTimestamp, minTs > 0 {
            if let entry = cat.getEntry(forFilename: filename), entry.timestamp < minTs {
                return nil // 缩略图时间戳过旧，失效
            }
        }
        return cat.getImageData(forFilename: filename)
    }
    
    // MARK: - 保证目录 Catalog 加载就绪 (单次网络 IO 覆盖整目录)
    
    public func ensureCatalogLoaded(directoryId: String, syncDelegate: (any ThumbnailRemoteSyncDelegate)? = nil) async -> ThumbnailCatalog {
        lock.lock()
        if let existing = memoryCatalogs[directoryId] {
            touchLRU(directoryId: directoryId)
            lock.unlock()
            return existing
        }
        lock.unlock()
        
        // 1. 尝试从本地磁盘缓存读取
        let diskURL = localCatalogURL(directoryId: directoryId)
        if let diskData = try? Data(contentsOf: diskURL),
           let diskCatalog = ThumbnailCatalog.deserialize(from: diskData) {
            lock.lock()
            memoryCatalogs[directoryId] = diskCatalog
            touchLRU(directoryId: directoryId)
            lock.unlock()
            return diskCatalog
        }
        
        // 2. 尝试从远程目录加载 .thumbnails.catalog
        if let delegate = syncDelegate {
            do {
                let items = try await delegate.listDirectoryForThumbnails(directoryId: directoryId)
                if let catalogItem = items.first(where: { $0.name == ThumbnailCatalog.catalogFileName }) {
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("cat_\(UUID().uuidString).bin")
                    
                    try await delegate.downloadThumbnailFile(fileId: catalogItem.id, to: tempURL)
                    if let remoteData = try? Data(contentsOf: tempURL),
                       let remoteCatalog = ThumbnailCatalog.deserialize(from: remoteData) {
                        try? FileManager.default.removeItem(at: tempURL)
                        
                        // 写入本地磁盘缓存
                        try? remoteData.write(to: diskURL, options: .atomic)
                        
                        lock.lock()
                        memoryCatalogs[directoryId] = remoteCatalog
                        touchLRU(directoryId: directoryId)
                        lock.unlock()
                        
                        Logger.shared.success(.sync, "✅ Loaded remote .thumbnails.catalog for directory \(directoryId) (\(remoteCatalog.count) entries)")
                        return remoteCatalog
                    }
                    try? FileManager.default.removeItem(at: tempURL)
                }
            } catch {
                Logger.shared.warning(.sync, "⚠️ Could not check/download remote catalog for \(directoryId): \(error.localizedDescription)")
            }
        }
        
        // 3. 若无远程 catalog，初始化一个新的空 catalog
        let emptyCatalog = ThumbnailCatalog()
        lock.lock()
        memoryCatalogs[directoryId] = emptyCatalog
        touchLRU(directoryId: directoryId)
        lock.unlock()
        return emptyCatalog
    }
    
    // MARK: - 记录缩略图并防抖异步刷盘上传 (支持云端增量合并)
    
    public func recordThumbnail(
        directoryId: String,
        filename: String,
        fileId: String,
        imageData: Data,
        timestamp: Int64,
        width: Int,
        height: Int,
        syncDelegate: (any ThumbnailRemoteSyncDelegate)? = nil
    ) {
        lock.lock()
        let catalog = memoryCatalogs[directoryId] ?? ThumbnailCatalog()
        memoryCatalogs[directoryId] = catalog
        touchLRU(directoryId: directoryId)
        lock.unlock()
        
        catalog.addOrUpdate(
            filename: filename,
            fileId: fileId,
            imageData: imageData,
            timestamp: timestamp,
            width: width,
            height: height
        )
        
        // 保存到本地磁盘
        let serialized = catalog.serialize()
        let diskURL = localCatalogURL(directoryId: directoryId)
        try? serialized.write(to: diskURL, options: .atomic)
        
        // 防抖 800ms 异步上传云端，上传前检查远端并执行差异合并
        if let delegate = syncDelegate {
            lock.lock()
            pendingSaveTasks[directoryId]?.cancel()
            pendingSaveTasks[directoryId] = Task { [weak self, catalog] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard self != nil else { return }
                
                // 尝试读取云端最新版本进行双向增量合并，避免多端并发覆写
                if let items = try? await delegate.listDirectoryForThumbnails(directoryId: directoryId),
                   let remoteCatItem = items.first(where: { $0.name == ThumbnailCatalog.catalogFileName }) {
                    let tempRemoteURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("merge_\(UUID().uuidString).bin")
                    do {
                        try await delegate.downloadThumbnailFile(fileId: remoteCatItem.id, to: tempRemoteURL)
                        if let remoteData = try? Data(contentsOf: tempRemoteURL),
                           let remoteCatalog = ThumbnailCatalog.deserialize(from: remoteData) {
                            catalog.merge(with: remoteCatalog)
                        }
                    } catch {}
                    try? FileManager.default.removeItem(at: tempRemoteURL)
                }
                
                let dataToUpload = catalog.serialize()
                let tempUploadURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("upload_\(UUID().uuidString)_\(ThumbnailCatalog.catalogFileName)")
                
                do {
                    try dataToUpload.write(to: tempUploadURL, options: .atomic)
                    try await delegate.uploadThumbnailFile(localURL: tempUploadURL, name: ThumbnailCatalog.catalogFileName, parentId: directoryId)
                    try? FileManager.default.removeItem(at: tempUploadURL)
                    Logger.shared.success(.sync, "✅ Synced .thumbnails.catalog for directory \(directoryId) (\(catalog.count) items, \(dataToUpload.count) bytes)")
                } catch {
                    Logger.shared.warning(.sync, "⚠️ Failed to sync .thumbnails.catalog for \(directoryId): \(error.localizedDescription)")
                }
            }
            lock.unlock()
        }
    }
    
    // MARK: - 移除缩略图条目 (本地磁盘同步更新 + 防抖云端同步)
    
    public func removeThumbnail(
        directoryId: String,
        filename: String? = nil,
        fileId: String? = nil,
        syncDelegate: (any ThumbnailRemoteSyncDelegate)? = nil
    ) {
        lock.lock()
        guard let catalog = memoryCatalogs[directoryId] else {
            lock.unlock()
            return
        }
        touchLRU(directoryId: directoryId)
        lock.unlock()
        
        if let fn = filename {
            catalog.remove(filename: fn)
        }
        if let fId = fileId {
            catalog.remove(fileId: fId)
        }
        
        // 更新本地磁盘文件
        let serialized = catalog.serialize()
        let diskURL = localCatalogURL(directoryId: directoryId)
        try? serialized.write(to: diskURL, options: .atomic)
        
        // 若提供了 syncDelegate，防抖调度上传更新
        if let delegate = syncDelegate {
            lock.lock()
            pendingSaveTasks[directoryId]?.cancel()
            pendingSaveTasks[directoryId] = Task { [weak self, catalog] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard self != nil else { return }
                let dataToUpload = catalog.serialize()
                let tempUploadURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("upload_\(UUID().uuidString)_\(ThumbnailCatalog.catalogFileName)")
                do {
                    try dataToUpload.write(to: tempUploadURL, options: .atomic)
                    try await delegate.uploadThumbnailFile(localURL: tempUploadURL, name: ThumbnailCatalog.catalogFileName, parentId: directoryId)
                    try? FileManager.default.removeItem(at: tempUploadURL)
                    Logger.shared.success(.sync, "✅ Synced .thumbnails.catalog after removal for \(directoryId)")
                } catch {
                    Logger.shared.warning(.sync, "⚠️ Failed to sync .thumbnails.catalog after removal: \(error)")
                }
            }
            lock.unlock()
        }
    }
    
    // MARK: - Backward-compatible overloads with `vfs` parameter
    
    public func ensureCatalogLoaded(directoryId: String, vfs: (any ThumbnailRemoteSyncDelegate)?) async -> ThumbnailCatalog {
        return await ensureCatalogLoaded(directoryId: directoryId, syncDelegate: vfs)
    }

    public func recordThumbnail(
        directoryId: String,
        filename: String,
        fileId: String,
        imageData: Data,
        timestamp: Int64,
        width: Int,
        height: Int,
        vfs: (any ThumbnailRemoteSyncDelegate)?
    ) {
        recordThumbnail(
            directoryId: directoryId,
            filename: filename,
            fileId: fileId,
            imageData: imageData,
            timestamp: timestamp,
            width: width,
            height: height,
            syncDelegate: vfs
        )
    }

    public func removeThumbnail(
        directoryId: String,
        filename: String? = nil,
        fileId: String? = nil,
        vfs: (any ThumbnailRemoteSyncDelegate)?
    ) {
        removeThumbnail(
            directoryId: directoryId,
            filename: filename,
            fileId: fileId,
            syncDelegate: vfs
        )
    }
    
    // MARK: - 缓存清除
    
    public func clearAll() {
        lock.lock()
        memoryCatalogs.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: catalogsDiskDir)
        try? FileManager.default.createDirectory(at: catalogsDiskDir, withIntermediateDirectories: true)
    }
}
