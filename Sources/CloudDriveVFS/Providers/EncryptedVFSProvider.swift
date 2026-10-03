//
//  EncryptedVFSProvider.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  加密 VFS 驱动 (基于 Cryptomator Format 7/8, AES-SIV / AES-GCM)
//

import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CloudDrivePersistence
import CloudDriveCrypto
import CloudDriveVaultFormat
import CloudDriveSync
import CloudDriveCache
import CloudDriveSystem

/// 加密 VFS 驱动实现
public final class EncryptedVFSProvider: VFSProvider, @unchecked Sendable {
    public let vaultId: String
    public var isEncrypted: Bool { true }
    public let rootId: String = "ROOT"
    
    public let cryptomatorFormat: CryptomatorFormat
    public let database: VFSDatabase
    public let storageClient: StorageClient
    private let syncManager: SyncManager
    private let cacheManager: CacheManager
    private let operationManager: FileOperationTracker
    
    private var directoryCacheTimestamps: [String: Date] = [:]
    private let directoryCacheLock = NSLock()
    private let directoryCacheTTL: TimeInterval = 45.0
    
    public init(
        vaultId: String,
        cryptomatorFormat: CryptomatorFormat,
        storageClient: StorageClient,
        database: VFSDatabase,
        syncManager: SyncManager = SyncManager.shared,
        cacheManager: CacheManager = CacheManager.shared,
        operationManager: FileOperationTracker = FileOperationTracker.shared
    ) {
        self.vaultId = vaultId
        self.cryptomatorFormat = cryptomatorFormat
        self.storageClient = storageClient
        self.database = database
        self.syncManager = syncManager
        self.cacheManager = cacheManager
        self.operationManager = operationManager
    }
    
    // MARK: - 查询项
    
    public func getItem(id: String) throws -> VirtualFileItem? {
        do {
            var dirRecord = try? database.getDirectory(id: id)
            if dirRecord == nil && !id.hasPrefix("/") {
                dirRecord = try? database.getDirectory(id: "/\(id)")
            } else if dirRecord == nil && id.hasPrefix("/") {
                dirRecord = try? database.getDirectory(id: String(id.dropFirst()))
            }
            if let dir = dirRecord {
                return VirtualFileItem(
                    id: dir.id,
                    name: dir.name,
                    isDirectory: true,
                    size: 0,
                    modifiedAt: dir.modifiedAt,
                    parentId: dir.parentId ?? rootId,
                    syncStatus: syncManager.getMetadata(fileId: dir.id)?.syncStatus ?? .synced,
                    remotePath: dir.remotePath.isEmpty ? dir.id : dir.remotePath
                )
            }
            
            var fileRecord = try? database.getFile(id: id)
            if fileRecord == nil && !id.hasPrefix("file_") {
                fileRecord = try? database.getFile(id: "file_\(id)")
            }
            if fileRecord == nil && !id.hasPrefix("/") {
                fileRecord = try? database.getFile(id: "/\(id)")
            } else if fileRecord == nil && id.hasPrefix("/") {
                fileRecord = try? database.getFile(id: String(id.dropFirst()))
            }
            if let file = fileRecord {
                return VirtualFileItem(
                    id: file.id,
                    name: file.name,
                    isDirectory: false,
                    size: file.size,
                    modifiedAt: file.modifiedAt,
                    parentId: file.parentId,
                    syncStatus: syncManager.getMetadata(fileId: file.id)?.syncStatus ?? .synced,
                    remotePath: file.remotePath.isEmpty ? file.id : file.remotePath,
                    etag: syncManager.getMetadata(fileId: file.id)?.etag
                )
            }
        } catch {
            Logger.shared.warning(.sync, "getItem: Database query failed: \(error)")
        }
        return nil
    }
    
    // MARK: - 目录列举
    
    public func listDirectory(directoryId: String, forceRefresh: Bool = false) async throws -> [VirtualFileItem] {
        if forceRefresh {
            return try await listDirectoryFromRemoteAsync(directoryId: directoryId)
        }
        
        let cachedItems = (try? database.listChildren(parentId: directoryId)) ?? []
        directoryCacheLock.lock()
        let lastFetch = directoryCacheTimestamps[directoryId]
        let isStale = lastFetch == nil || Date().timeIntervalSince(lastFetch!) > directoryCacheTTL
        directoryCacheLock.unlock()
        
        if !cachedItems.isEmpty {
            if isStale {
                Task { [weak self] in
                    _ = try? await self?.listDirectoryFromRemoteAsync(directoryId: directoryId)
                }
            }
            return cachedItems
        }
        
        return try await listDirectoryFromRemoteAsync(directoryId: directoryId)
    }
    
    public func listDirectoryFromRemoteAsync(directoryId: String) async throws -> [VirtualFileItem] {
        let dirIdData = cryptomatorFormat.dirIdData(from: directoryId)
        let items = try await cryptomatorFormat.listDirectory(dirId: dirIdData)
        
        let previousItems = (try? database.listChildren(parentId: directoryId)) ?? []
        let previousIds = Set(previousItems.map { $0.id })
        let currentIds = Set(items.map { $0.id })
        let deletedIds = previousIds.subtracting(currentIds)
        for delId in deletedIds {
            if let meta = syncManager.getMetadata(fileId: delId),
               meta.syncStatus.protectsLocalChanges {
                continue
            }
            if database.getAllDescendantFileIds(directoryId: delId).contains(where: { syncManager.getMetadata(fileId: $0)?.syncStatus.protectsLocalChanges == true }) {
                var protected = syncManager.getMetadata(fileId: delId) ?? FileMetadata(fileId: delId, name: previousItems.first(where: { $0.id == delId })?.name ?? delId, parentId: directoryId, isDirectory: true, syncStatus: .conflict)
                protected.syncStatus = .conflict
                syncManager.updateMetadata(protected)
                continue
            }
            try? database.deleteFile(id: delId)
            try? database.deleteDirectory(id: delId)
            try? cacheManager.removeCachedFile(fileId: delId)
            cacheManager.removeDirectoryCache(forDirectoryPrefix: delId)
            syncManager.removeMetadata(fileId: delId)
            syncManager.removeDirectoryMetadata(forDirectoryPrefix: delId)
            ThumbnailManager.shared.invalidate(fileId: delId)
            DirectoryThumbnailCatalogManager.shared.removeThumbnail(directoryId: directoryId, fileId: delId)
        }
        
        for item in items {
            if let meta = syncManager.getMetadata(fileId: item.id), meta.syncStatus == .pendingDelete {
                continue
            }
            if syncManager.getMetadata(fileId: item.id)?.syncStatus.protectsLocalChanges == true {
                // Keep local content/size and its edit baseline until the pending change resolves.
                var metadata = syncManager.getMetadata(fileId: item.id)!
                metadata.remoteModifiedAt = item.modifiedAt
                syncManager.updateMetadata(metadata)
            } else {
                try insertItemIntoDatabase(item)
                if let existingMeta = syncManager.getMetadata(fileId: item.id) {
                    if existingMeta.syncStatus == .synced && (existingMeta.etag != item.etag || existingMeta.remoteModifiedAt != item.modifiedAt) {
                        var updated = existingMeta
                        updated.etag = item.etag
                        updated.remoteModifiedAt = item.modifiedAt
                        syncManager.updateMetadata(updated)
                    }
                } else {
                    syncManager.updateMetadata(FileMetadata(
                        fileId: item.id,
                        name: item.name,
                        parentId: item.parentId,
                        isDirectory: item.isDirectory,
                        syncStatus: .synced,
                        remotePath: item.remotePath,
                        size: item.size,
                        localModifiedAt: item.modifiedAt,
                        remoteModifiedAt: item.modifiedAt,
                        etag: item.etag,
                        downloadProgress: 1.0,
                        lastSyncTime: Date()
                    ))
                }
            }
        }
        
        directoryCacheLock.lock()
        directoryCacheTimestamps[directoryId] = Date()
        directoryCacheLock.unlock()
        
        var mergedItems = items.compactMap { item -> VirtualFileItem? in
            if let meta = syncManager.getMetadata(fileId: item.id), meta.syncStatus == .pendingDelete {
                return nil
            }
            guard let metadata = syncManager.getMetadata(fileId: item.id), metadata.syncStatus.protectsLocalChanges else { return item }
            var localItem = previousItems.first(where: { $0.id == item.id }) ?? item
            localItem.syncStatus = metadata.syncStatus
            localItem.etag = metadata.etag
            return localItem
        }
        for prev in previousItems {
            if !currentIds.contains(prev.id) {
                if let meta = syncManager.getMetadata(fileId: prev.id),
                   meta.syncStatus.protectsLocalChanges {
                    var protected = prev
                    protected.syncStatus = meta.syncStatus
                    protected.etag = meta.etag
                    mergedItems.append(protected)
                }
            }
        }
        return mergedItems
    }
    
    // MARK: - 目录创建
    
    public func createDirectory(name: String, parentId: String) async throws -> VirtualFileItem {
        let parentDirId = cryptomatorFormat.dirIdData(from: parentId)
        let item = try await cryptomatorFormat.createDirectory(name: name, parentDirId: parentDirId)
        try insertItemIntoDatabase(item)
        return item
    }
    
    /// Replays an offline mkdir without changing the parent IDs of its pending children.
    public func createDirectory(name: String, parentId: String, directoryId: String) async throws -> VirtualFileItem {
        let item = try await cryptomatorFormat.createDirectory(name: name, parentDirId: cryptomatorFormat.dirIdData(from: parentId), directoryId: directoryId)
        try insertItemIntoDatabase(item)
        return item
    }

    // MARK: - 上传
    
    public func uploadFile(localURL: URL, name: String, parentId: String) async throws -> VirtualFileItem {
        try await uploadFile(localURL: localURL, name: name, parentId: parentId, mode: .createIfAbsent)
    }

    public func uploadFile(localURL: URL, name: String, parentId: String, expectedETag: String?) async throws -> VirtualFileItem {
        let mode: StorageWriteMode
        if let etag = expectedETag {
            mode = .replace(expectedETag: etag)
        } else {
            let existsLocally = (try? database.listChildren(parentId: parentId))?.contains(where: { $0.name == name }) ?? false
            mode = existsLocally ? .forceOverwrite : .createIfAbsent
        }
        return try await uploadFile(localURL: localURL, name: name, parentId: parentId, mode: mode)
    }

    public func uploadFile(localURL: URL, name: String, parentId: String, mode: StorageWriteMode) async throws -> VirtualFileItem {
        let parentDirId = cryptomatorFormat.dirIdData(from: parentId)
        let item: VirtualFileItem
        do {
            item = try await cryptomatorFormat.uploadFile(localURL: localURL, name: name, parentDirId: parentDirId, mode: mode)
        } catch {
            if (error as? StorageError)?.isPreconditionFailure == true {
                let (fileC9rPath, _, encName, _) = (try? cryptomatorFormat.getFileRemotePath(name: name, parentDirId: parentDirId)) ?? ("", false, "", nil)
                let fileId = "file_\(encName)"
                try? cacheManager.cacheFile(fileId: fileId, from: localURL)
                let cachePath = cacheManager.localPath(for: fileId).path
                let attrs = (try? FileManager.default.attributesOfItem(atPath: localURL.path)) ?? [:]
                let fileSize = attrs[.size] as? Int64 ?? 0
                syncManager.updateMetadata(FileMetadata(
                    fileId: fileId,
                    name: name,
                    parentId: parentId,
                    isDirectory: false,
                    syncStatus: .conflict,
                    localPath: cachePath,
                    remotePath: fileC9rPath,
                    size: fileSize,
                    localModifiedAt: Date()
                ))
            }
            throw error
        }
        try insertItemIntoDatabase(item)
        
        let cachePath = cacheManager.localPath(for: item.id).path
        syncManager.updateMetadata(FileMetadata(
            fileId: item.id,
            name: item.name,
            parentId: item.parentId,
            isDirectory: false,
            syncStatus: .synced,
            localPath: cachePath,
            remotePath: item.remotePath ?? "",
            size: item.size,
            localModifiedAt: item.modifiedAt,
            remoteModifiedAt: item.modifiedAt,
            etag: item.etag,
            lastSyncTime: Date()
        ))
        return item
    }
    
    // MARK: - 下载
    
    public func downloadFile(fileId: String, to destinationURL: URL, progress: ((Double) -> Void)? = nil) async throws {
        var file = try? database.getFile(id: fileId)
        if file == nil && !fileId.hasPrefix("file_") {
            file = try? database.getFile(id: "file_\(fileId)")
        }
        guard let file = file else {
            throw VFSError.fileNotFound
        }
        let deliveredETag = try await cryptomatorFormat.downloadFile(remotePath: file.remotePath, to: destinationURL, progress: progress)
        var metadata = syncManager.getMetadata(fileId: file.id) ?? FileMetadata(fileId: file.id, name: file.name, parentId: file.parentId, isDirectory: false, syncStatus: .synced)
        if !metadata.syncStatus.protectsLocalChanges {
            metadata.etag = deliveredETag
            metadata.remotePath = file.remotePath
            metadata.localPath = destinationURL.path
            metadata.syncStatus = .synced
            metadata.lastSyncTime = Date()
            syncManager.updateMetadata(metadata)
        }
    }
    
    // MARK: - 删除
    
    public func delete(itemId: String) async throws {
        let remotePath: String
        let isDir: Bool
        if let f = try database.getFile(id: itemId) {
            remotePath = f.remotePath
            isDir = false
        } else if let d = try database.getDirectory(id: itemId) {
            remotePath = d.remotePath
            isDir = true
        } else if let meta = syncManager.getMetadata(fileId: itemId), let mPath = meta.remotePath, !mPath.isEmpty {
            remotePath = mPath
            isDir = meta.isDirectory
        } else {
            Logger.shared.error(.sync, "delete: Cannot resolve real remote path for \(itemId), aborting")
            throw VFSError.fileNotFound
        }
        
        let dirIdData = isDir ? cryptomatorFormat.dirIdData(from: itemId) : nil
        try await cryptomatorFormat.deleteItem(remotePath: remotePath, dirIdData: dirIdData)
        if isDir {
            let childFileIds = database.getAllDescendantFileIds(directoryId: itemId)
            for childId in childFileIds {
                try? cacheManager.removeCachedFile(fileId: childId)
                syncManager.removeMetadata(fileId: childId)
                ThumbnailManager.shared.invalidate(fileId: childId)
            }
            try database.deleteDirectory(id: itemId)
            cacheManager.removeDirectoryCache(forDirectoryPrefix: itemId)
            syncManager.removeDirectoryMetadata(forDirectoryPrefix: itemId)
        } else {
            try database.deleteFile(id: itemId)
            try? cacheManager.removeCachedFile(fileId: itemId)
            ThumbnailManager.shared.invalidate(fileId: itemId)
        }
        syncManager.removeMetadata(fileId: itemId)
    }
    
    // MARK: - 移动与重命名
    
    public func moveItem(itemId: String, newParentId: String, newName: String? = nil) async throws -> VirtualFileItem {
        var fileRecord = try? database.getFile(id: itemId)
        if fileRecord == nil && !itemId.hasPrefix("file_") {
            fileRecord = try? database.getFile(id: "file_\(itemId)")
        }
        
        if let file = fileRecord {
            let finalName = newName ?? file.name
            let newParentDirId = cryptomatorFormat.dirIdData(from: newParentId)
            let (newRemotePath, isShortened, newEncName, shortenedDirPath) = try cryptomatorFormat.getFileRemotePath(name: finalName, parentDirId: newParentDirId)
            let newFileId = "file_\(newEncName)"
            
            var queuedMove = false
            let isPending = syncManager.hasPendingUpload(fileId: file.id) || file.id.hasPrefix("pending_") || (syncManager.getMetadata(fileId: file.id)?.syncStatus == .pendingUpload)
            if isPending {
                syncManager.updatePendingOperation(oldFileId: file.id, newFileId: newFileId, newRemotePath: newRemotePath, newName: finalName, newParentId: newParentId, sourceRemotePath: file.remotePath)
            } else {
                do {
                    let oldSourcePath: String
                    if file.remotePath.hasSuffix("/contents.c9r") && file.remotePath.contains(".c9s/") {
                        oldSourcePath = (file.remotePath as NSString).deletingLastPathComponent
                    } else {
                        oldSourcePath = file.remotePath
                    }
                    
                    if isShortened, let sDir = shortenedDirPath {
                        if (try? await storageClient.exists(path: sDir)) != true {
                            try await storageClient.createDirectory(path: sDir)
                        }
                        let tempNameURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        if let encData = newEncName.data(using: .utf8) {
                            try encData.write(to: tempNameURL)
                            try await storageClient.uploadFile(localURL: tempNameURL, to: "\(sDir)/name.c9s") { _ in }
                            try? FileManager.default.removeItem(at: tempNameURL)
                        }
                        try await storageClient.move(from: file.remotePath, to: newRemotePath)
                        if oldSourcePath != file.remotePath {
                            try? await storageClient.delete(path: oldSourcePath)
                        }
                    } else {
                        let newParentDirPath = try cryptomatorFormat.getDirPath(dirId: newParentDirId)
                        if (try? await storageClient.exists(path: newParentDirPath)) != true {
                            try await storageClient.createDirectory(path: newParentDirPath)
                        }
                        try await storageClient.move(from: file.remotePath, to: newRemotePath)
                        if oldSourcePath != file.remotePath {
                            try? await storageClient.delete(path: oldSourcePath)
                        }
                    }
                } catch {
                    guard VFSOperationErrorPolicy.permitsOfflineRetry(error) else { throw error }
                    try syncManager.enqueuePersistent(.move(itemId: newFileId, sourceRemotePath: file.remotePath, targetRemotePath: newRemotePath), startProcessing: false)
                    queuedMove = true
                }
            }
            
            try? database.deleteFile(id: file.id)
            try? database.insertFile(
                id: newFileId,
                name: finalName,
                parentId: newParentId,
                size: file.size,
                encryptedName: finalName,
                remotePath: newRemotePath
            )
            
            let wasCached = cacheManager.isCached(fileId: file.id)
            if wasCached {
                try? cacheManager.moveCache(from: file.id, to: newFileId)
            }
            
            let oldMeta = syncManager.getMetadata(fileId: file.id)
            let targetSyncStatus: SyncStatus = queuedMove ? .pendingMove : (isPending ? .pendingUpload : (wasCached ? .synced : (oldMeta?.syncStatus ?? .cloudOnly)))
            syncManager.moveMetadata(
                from: file.id,
                to: newFileId,
                newParentId: newParentId,
                newName: finalName,
                newRemotePath: newRemotePath,
                fallbackStatus: targetSyncStatus
            )
            if queuedMove { syncManager.processSyncQueue() }
            
            return VirtualFileItem(
                id: newFileId,
                name: finalName,
                isDirectory: false,
                size: file.size,
                modifiedAt: Date(),
                parentId: newParentId,
                syncStatus: targetSyncStatus,
                remotePath: newRemotePath
            )
        } else if let dir = try? database.getDirectory(id: itemId) {
            let finalName = newName ?? dir.name
            let newParentDirId = cryptomatorFormat.dirIdData(from: newParentId)
            let (newRemotePath, isShortened, newEncName, shortenedDirPath) = try cryptomatorFormat.getDirectoryRemotePath(name: finalName, parentDirId: newParentDirId)
            
            let newParentDirPath = try cryptomatorFormat.getDirPath(dirId: newParentDirId)
            var queuedMove = false
            do {
                if (try? await storageClient.exists(path: newParentDirPath)) != true {
                    try await storageClient.createDirectory(path: newParentDirPath)
                }
                
                if isShortened, let sDir = shortenedDirPath {
                    if (try? await storageClient.exists(path: sDir)) != true {
                        try await storageClient.createDirectory(path: sDir)
                    }
                    let tempNameURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    if let encData = newEncName.data(using: .utf8) {
                        try encData.write(to: tempNameURL)
                        try await storageClient.uploadFile(localURL: tempNameURL, to: "\(sDir)/name.c9s") { _ in }
                        try? FileManager.default.removeItem(at: tempNameURL)
                    }
                    try await storageClient.move(from: "\(dir.remotePath)/dir.c9r", to: "\(newRemotePath)/dir.c9r")
                    try? await storageClient.delete(path: dir.remotePath)
                } else {
                    try await storageClient.move(from: dir.remotePath, to: newRemotePath)
                }
            } catch {
                guard VFSOperationErrorPolicy.permitsOfflineRetry(error) else { throw error }
                try syncManager.enqueuePersistent(.move(itemId: dir.id, sourceRemotePath: dir.remotePath, targetRemotePath: newRemotePath), startProcessing: false)
                queuedMove = true
            }
            
            try? database.insertDirectory(
                id: dir.id,
                name: finalName,
                parentId: newParentId,
                encryptedId: dir.encryptedId,
                remotePath: newRemotePath
            )
            
            if let oldMeta = syncManager.getMetadata(fileId: dir.id) {
                let updatedMeta = FileMetadata(
                    fileId: dir.id,
                    name: finalName,
                    parentId: newParentId,
                    isDirectory: true,
                    syncStatus: oldMeta.syncStatus,
                    remotePath: newRemotePath,
                    localModifiedAt: oldMeta.localModifiedAt,
                    remoteModifiedAt: Date()
                )
                syncManager.updateMetadata(updatedMeta)
            }
            
            let targetStatus: SyncStatus = queuedMove ? .pendingMove : .synced
            return VirtualFileItem(
                id: dir.id,
                name: finalName,
                isDirectory: true,
                size: 0,
                modifiedAt: Date(),
                parentId: newParentId,
                syncStatus: targetStatus,
                remotePath: newRemotePath
            )
        } else {
            throw VFSError.itemNotFound
        }
    }
    
    // MARK: - 复制
    
    public func copyItem(itemId: String, newParentId: String, newName: String? = nil) async throws -> VirtualFileItem {
        var fileRecord = try? database.getFile(id: itemId)
        if fileRecord == nil && !itemId.hasPrefix("file_") {
            fileRecord = try? database.getFile(id: "file_\(itemId)")
        }
        
        if let file = fileRecord {
            let finalName = newName ?? file.name
            let newParentDirId = cryptomatorFormat.dirIdData(from: newParentId)
            let (newRemotePath, isShortened, newEncName, shortenedDirPath) = try cryptomatorFormat.getFileRemotePath(name: finalName, parentDirId: newParentDirId)
            let newFileId = "file_\(newEncName)"
            try await storageClient.createDirectory(path: cryptomatorFormat.getDirPath(dirId: newParentDirId))
            if isShortened, let directory = shortenedDirPath {
                try await storageClient.createDirectory(path: directory)
                let nameURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: nameURL) }
                try Data(newEncName.utf8).write(to: nameURL)
                try await storageClient.uploadFile(localURL: nameURL, to: directory + "/name.c9s") { _ in }
            }
            try await storageClient.copy(from: file.remotePath, to: newRemotePath)
            
            try? database.insertFile(
                id: newFileId,
                name: finalName,
                parentId: newParentId,
                size: file.size,
                encryptedName: finalName,
                remotePath: newRemotePath
            )
            
            let wasCached = cacheManager.isCached(fileId: file.id)
            if wasCached {
                try? cacheManager.cloneCache(from: file.id, to: newFileId)
            }
            
            let targetSyncStatus: SyncStatus = wasCached ? .synced : .cloudOnly
            syncManager.updateMetadata(FileMetadata(
                fileId: newFileId,
                name: finalName,
                parentId: newParentId,
                isDirectory: false,
                syncStatus: targetSyncStatus,
                localPath: wasCached ? cacheManager.localPath(for: newFileId).path : nil,
                remotePath: newRemotePath,
                size: file.size,
                localModifiedAt: Date(),
                remoteModifiedAt: Date()
            ))
            
            return VirtualFileItem(
                id: newFileId,
                name: finalName,
                isDirectory: false,
                size: file.size,
                modifiedAt: Date(),
                parentId: newParentId,
                syncStatus: targetSyncStatus,
                remotePath: newRemotePath
            )
        } else if let dir = try? database.getDirectory(id: itemId) {
            let finalName = newName ?? dir.name
            let newParentDirId = cryptomatorFormat.dirIdData(from: newParentId)
            let newDirItem = try await cryptomatorFormat.createDirectory(name: finalName, parentDirId: newParentDirId)
            
            try? database.insertDirectory(
                id: newDirItem.id,
                name: finalName,
                parentId: newParentId,
                encryptedId: newDirItem.id,
                remotePath: newDirItem.remotePath ?? ""
            )
            
            syncManager.updateMetadata(FileMetadata(
                fileId: newDirItem.id,
                name: finalName,
                parentId: newParentId,
                isDirectory: true,
                syncStatus: .synced,
                remotePath: newDirItem.remotePath ?? "",
                localModifiedAt: Date(),
                remoteModifiedAt: Date()
            ))
            
            let children = try await listDirectoryFromRemoteAsync(directoryId: itemId)
            for child in children {
                _ = try await copyItem(itemId: child.id, newParentId: newDirItem.id, newName: child.name)
            }
            
            return VirtualFileItem(
                id: newDirItem.id,
                name: finalName,
                isDirectory: true,
                size: 0,
                modifiedAt: Date(),
                parentId: newParentId,
                syncStatus: .synced,
                remotePath: newDirItem.remotePath
            )
        } else {
            throw VFSError.itemNotFound
        }
    }
    
    // MARK: - 修改
    
    public func modifyFile(fileId: String, newContent: URL) async throws -> VirtualFileItem {
        let file = try database.getFile(id: fileId) ?? (fileId.hasPrefix("file_") ? nil : database.getFile(id: "file_" + fileId))
        guard let file = file else { throw VFSError.fileNotFound }
        var metadata = syncManager.getMetadata(fileId: file.id) ?? FileMetadata(fileId: file.id, name: file.name, parentId: file.parentId, isDirectory: false, syncStatus: .pendingUpload)
        metadata.syncStatus = .pendingUpload
        metadata.localPath = cacheManager.localPath(for: file.id).path
        metadata.localModifiedAt = Date()
        metadata.remotePath = file.remotePath
        metadata.size = (try FileManager.default.attributesOfItem(atPath: newContent.path)[.size] as? NSNumber)?.int64Value ?? 0
        syncManager.updateMetadata(metadata)
        try cacheManager.cacheFile(fileId: file.id, from: newContent)
        do {
            if storageClient.requiresETagForUpdate && metadata.etag == nil {
                throw StorageError.notSupported("Download the current revision before replacing a WebDAV file without a saved ETag")
            }
            let item = try await cryptomatorFormat.uploadFile(localURL: cacheManager.localPath(for: file.id), name: file.name, parentDirId: cryptomatorFormat.dirIdData(from: file.parentId), expectedETag: metadata.etag)
            try insertItemIntoDatabase(item)
            metadata.etag = item.etag
            metadata.remoteModifiedAt = item.modifiedAt
            metadata.syncStatus = .synced
            metadata.lastSyncTime = Date()
            syncManager.updateMetadata(metadata)
            return item
        } catch {
            if (error as? StorageError)?.isPreconditionFailure == true {
                metadata.syncStatus = .conflict
                syncManager.updateMetadata(metadata)
            }
            throw error
        }
    }

    public func invalidateDirectoryCache(directoryId: String?) {
        directoryCacheLock.lock()
        if let dirId = directoryId {
            directoryCacheTimestamps.removeValue(forKey: dirId)
        } else {
            directoryCacheTimestamps.removeAll()
        }
        directoryCacheLock.unlock()
    }
    
    private func insertItemIntoDatabase(_ item: VirtualFileItem) throws {
            if item.isDirectory {
                try database.insertDirectory(id: item.id, name: item.name, parentId: item.parentId, encryptedId: item.id, remotePath: item.remotePath ?? "", modifiedAt: item.modifiedAt)
            } else {
                try database.insertFile(id: item.id, name: item.name, parentId: item.parentId, size: item.size, encryptedName: item.name, remotePath: item.remotePath ?? "", modifiedAt: item.modifiedAt)
            }
            var metadata = syncManager.getMetadata(fileId: item.id) ?? FileMetadata(fileId: item.id, name: item.name, parentId: item.parentId, isDirectory: item.isDirectory, syncStatus: item.isDirectory ? .synced : .cloudOnly)
            metadata.remotePath = item.remotePath
            metadata.remoteModifiedAt = item.modifiedAt
            if !cacheManager.isCached(fileId: item.id) && !metadata.syncStatus.protectsLocalChanges {
                metadata.etag = item.etag
                metadata.size = item.size
            }
            syncManager.updateMetadata(metadata)
    }
}
