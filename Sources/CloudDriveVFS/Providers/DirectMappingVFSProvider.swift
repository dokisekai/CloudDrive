//
//  DirectMappingVFSProvider.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  直接映射 VFS 驱动 (完全透明映射 WebDAV/S3/SMB/FTP/Local)
//

import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CloudDrivePersistence
import CloudDriveSync
import CloudDriveCache
import CloudDriveSystem

/// 直接透明映射 VFS 驱动实现
public final class DirectMappingVFSProvider: VFSProvider, @unchecked Sendable {
    public let vaultId: String
    public let storagePath: String
    public var isEncrypted: Bool { false }
    public let rootId: String = "ROOT"
    
    public let storageClient: StorageClient
    public let database: VFSDatabase
    private let syncManager: SyncManager
    private let cacheManager: CacheManager
    private let operationManager: FileOperationTracker
    
    private var directoryCacheTimestamps: [String: Date] = [:]
    private let directoryCacheLock = NSLock()
    private let directoryCacheTTL: TimeInterval = 45.0
    
    public init(
        vaultId: String,
        storagePath: String,
        storageClient: StorageClient,
        database: VFSDatabase,
        syncManager: SyncManager = SyncManager.shared,
        cacheManager: CacheManager = CacheManager.shared,
        operationManager: FileOperationTracker = FileOperationTracker.shared
    ) {
        self.vaultId = vaultId
        self.storagePath = storagePath
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
        let remotePath: String
        if let dir = try? database.getDirectory(id: directoryId), !dir.remotePath.isEmpty {
            remotePath = dir.remotePath
        } else {
            remotePath = (directoryId == rootId || directoryId == "/") ? storagePath : directoryId
        }
        let resources = try await storageClient.listDirectory(path: remotePath)
        
        let items = resources.map { resource -> VirtualFileItem in
            let fullPath: String
            if remotePath == "/" {
                fullPath = "/\(resource.displayName)"
            } else if remotePath.hasSuffix("/") {
                fullPath = "\(remotePath)\(resource.displayName)"
            } else {
                fullPath = "\(remotePath)/\(resource.displayName)"
            }
            
            return VirtualFileItem(
                id: fullPath,
                name: resource.displayName,
                isDirectory: resource.isDirectory,
                size: resource.contentLength,
                modifiedAt: resource.lastModified ?? Date(),
                parentId: directoryId,
                remotePath: fullPath,
                etag: resource.etag
            )
        }
        
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
        let remotePath: String
        if let parent = try? database.getDirectory(id: parentId) {
            let pPath = parent.remotePath.isEmpty ? parent.id : parent.remotePath
            if pPath == "/" || pPath.isEmpty || pPath == rootId {
                remotePath = rootChildPath(name)
            } else if pPath.hasSuffix("/") {
                remotePath = "\(pPath)\(name)"
            } else {
                remotePath = "\(pPath)/\(name)"
            }
        } else {
            if parentId == rootId || parentId == "/" || parentId.isEmpty {
                remotePath = rootChildPath(name)
            } else if parentId.hasSuffix("/") {
                remotePath = "\(parentId)\(name)"
            } else {
                remotePath = "\(parentId)/\(name)"
            }
        }
        
        let opId = operationManager.addOperation(type: .create, fileName: name, filePath: remotePath)
        do {
            operationManager.updateOperation(id: opId, status: .inProgress)
            try await storageClient.createDirectory(path: remotePath)
        } catch {
            operationManager.updateOperation(id: opId, status: .failed, errorMessage: error.localizedDescription)
            throw VFSError.directoryCreationFailed(error.localizedDescription)
        }
        
        let dirId = remotePath
        try? database.insertDirectory(id: dirId, name: name, parentId: parentId, encryptedId: name, remotePath: remotePath)
        
        let metadata = FileMetadata(
            fileId: dirId,
            name: name,
            parentId: parentId,
            isDirectory: true,
            syncStatus: .synced,
            remotePath: remotePath,
            localModifiedAt: Date(),
            remoteModifiedAt: Date()
        )
        syncManager.updateMetadata(metadata)
        operationManager.updateOperation(id: opId, status: .completed)
        
        return VirtualFileItem(
            id: dirId,
            name: name,
            isDirectory: true,
            size: 0,
            modifiedAt: Date(),
            parentId: parentId,
            syncStatus: .synced,
            remotePath: remotePath
        )
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
        let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path)
        let fileSize = attrs?[.size] as? UInt64 ?? 0
        
        let remoteFilePath: String
        if let parent = try? database.getDirectory(id: parentId) {
            if parent.remotePath == "/" {
                remoteFilePath = rootChildPath(name)
            } else if parent.remotePath.hasSuffix("/") {
                remoteFilePath = "\(parent.remotePath)\(name)"
            } else {
                remoteFilePath = "\(parent.remotePath)/\(name)"
            }
        } else {
            if parentId == rootId || parentId == "/" {
                remoteFilePath = rootChildPath(name)
            } else if parentId.hasSuffix("/") {
                remoteFilePath = "\(parentId)\(name)"
            } else {
                remoteFilePath = "\(parentId)/\(name)"
            }
        }
        
        let fileId = remoteFilePath
        let cachePath = cacheManager.localPath(for: fileId).path
        let opId = operationManager.addOperation(type: .upload, fileName: name, filePath: remoteFilePath)
        let parentDir = URL(fileURLWithPath: remoteFilePath).deletingLastPathComponent().path
        if parentDir != "/" && !parentDir.isEmpty {
            try? await storageClient.createDirectory(path: parentDir)
        }
        
        let committedETag: String?
        do {
            committedETag = try await storageClient.uploadFile(localURL: localURL, to: remoteFilePath, mode: mode) { p in
                self.operationManager.updateProgress(id: opId, progress: p)
            }
        } catch {
            operationManager.updateOperation(id: opId, status: .failed, errorMessage: error.localizedDescription)
            if (error as? StorageError)?.isPreconditionFailure == true {
                try? cacheManager.cacheFile(fileId: fileId, from: localURL)
                let conflictMeta = FileMetadata(
                    fileId: fileId,
                    name: name,
                    parentId: parentId,
                    isDirectory: false,
                    syncStatus: .conflict,
                    localPath: cachePath,
                    remotePath: remoteFilePath,
                    size: Int64(fileSize),
                    localModifiedAt: Date()
                )
                syncManager.updateMetadata(conflictMeta)
            }
            throw error
        }
        
        try? database.insertFile(id: fileId, name: name, parentId: parentId, size: Int64(fileSize), encryptedName: name, remotePath: remoteFilePath)
        
        let metadata = FileMetadata(
            fileId: fileId,
            name: name,
            parentId: parentId,
            isDirectory: false,
            syncStatus: .synced,
            localPath: cachePath,
            remotePath: remoteFilePath,
            size: Int64(fileSize),
            localModifiedAt: Date(),
            remoteModifiedAt: Date(),
            etag: committedETag,
            lastSyncTime: Date()
        )
        syncManager.updateMetadata(metadata)
        operationManager.updateOperation(id: opId, status: .completed)
        
        return VirtualFileItem(
            id: fileId,
            name: name,
            isDirectory: false,
            size: Int64(fileSize),
            modifiedAt: Date(),
            parentId: parentId,
            syncStatus: .synced,
            localPath: cachePath,
            remotePath: remoteFilePath,
            etag: committedETag
        )
    }
    
    // MARK: - 下载
    
    public func downloadFile(fileId: String, to destinationURL: URL, progress: ((Double) -> Void)? = nil) async throws {
        let parentDir = destinationURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        
        let file = try database.getFile(id: fileId)
        let previous = syncManager.getMetadata(fileId: fileId)
        let remotePath = file?.remotePath ?? fileId
        let deliveredETag = try await storageClient.downloadFile(path: remotePath, to: destinationURL, expectedETag: nil) { p in
            progress?(p)
        }
        var metadata = previous ?? FileMetadata(fileId: fileId, name: file?.name ?? destinationURL.lastPathComponent, parentId: file?.parentId ?? rootId, isDirectory: false, syncStatus: .synced)
        // GET's ETag is the editing baseline; a later listing must not silently replace it.
        if !metadata.syncStatus.protectsLocalChanges {
            metadata.etag = deliveredETag
            metadata.remotePath = remotePath
            metadata.syncStatus = .synced
            metadata.localPath = destinationURL.path
            metadata.lastSyncTime = Date()
        }
        syncManager.updateMetadata(metadata)
    }
    
    // MARK: - 删除
    
    public func delete(itemId: String) async throws {
        var fileRecord = try? database.getFile(id: itemId)
        if fileRecord == nil && !itemId.hasPrefix("/") {
            fileRecord = try? database.getFile(id: "/\(itemId)")
        } else if fileRecord == nil && itemId.hasPrefix("/") {
            fileRecord = try? database.getFile(id: String(itemId.dropFirst()))
        }
        if let file = fileRecord {
            let effectiveRemotePath = file.remotePath.isEmpty ? (file.id.hasPrefix("/") ? file.id : "/\(file.id)") : file.remotePath
            let fileName = URL(fileURLWithPath: itemId).lastPathComponent
            let opId = operationManager.addOperation(type: .delete, fileName: fileName, filePath: effectiveRemotePath)
            operationManager.updateOperation(id: opId, status: .inProgress)
            
            try await storageClient.delete(path: effectiveRemotePath)
            try? database.deleteFile(id: file.id)
            try? database.deleteFile(id: itemId)
            try? cacheManager.removeCachedFile(fileId: file.id)
            try? cacheManager.removeCachedFile(fileId: itemId)
            syncManager.removeMetadata(fileId: file.id)
            syncManager.removeMetadata(fileId: itemId)
            operationManager.updateOperation(id: opId, status: .completed)
            return
        }
        
        var dirRecord = try? database.getDirectory(id: itemId)
        if dirRecord == nil && !itemId.hasPrefix("/") {
            dirRecord = try? database.getDirectory(id: "/\(itemId)")
        } else if dirRecord == nil && itemId.hasPrefix("/") {
            dirRecord = try? database.getDirectory(id: String(itemId.dropFirst()))
        }
        if let directory = dirRecord {
            let effectiveRemotePath = directory.remotePath.isEmpty ? (directory.id.hasPrefix("/") ? directory.id : "/\(directory.id)") : directory.remotePath
            try await storageClient.delete(path: effectiveRemotePath)
            let childFileIds = database.getAllDescendantFileIds(directoryId: directory.id)
            for childId in childFileIds {
                try? cacheManager.removeCachedFile(fileId: childId)
                syncManager.removeMetadata(fileId: childId)
                ThumbnailManager.shared.invalidate(fileId: childId)
            }
            try? database.deleteDirectory(id: directory.id)
            try? database.deleteDirectory(id: itemId)
            cacheManager.removeDirectoryCache(forDirectoryPrefix: directory.id)
            cacheManager.removeDirectoryCache(forDirectoryPrefix: itemId)
            syncManager.removeDirectoryMetadata(forDirectoryPrefix: directory.id)
            syncManager.removeDirectoryMetadata(forDirectoryPrefix: itemId)
            syncManager.removeMetadata(fileId: directory.id)
            syncManager.removeMetadata(fileId: itemId)
            return
        }
        
        let remotePath = itemId
        try await storageClient.delete(path: remotePath)
        try? cacheManager.removeCachedFile(fileId: itemId)
        cacheManager.removeDirectoryCache(forDirectoryPrefix: itemId)
        syncManager.removeDirectoryMetadata(forDirectoryPrefix: itemId)
        syncManager.removeMetadata(fileId: itemId)
    }
    
    // MARK: - 移动与重命名
    
    public func moveItem(itemId: String, newParentId: String, newName: String? = nil) async throws -> VirtualFileItem {
        let sourcePath: String
        let itemName: String
        let isDirectory: Bool
        var fileSize: Int64 = 0
        
        var fileRecord = try? database.getFile(id: itemId)
        if fileRecord == nil && !itemId.hasPrefix("/") {
            fileRecord = try? database.getFile(id: "/\(itemId)")
        }
        var dirRecord = try? database.getDirectory(id: itemId)
        if dirRecord == nil && !itemId.hasPrefix("/") {
            dirRecord = try? database.getDirectory(id: "/\(itemId)")
        }
        
        if let file = fileRecord {
            sourcePath = file.remotePath.isEmpty ? (file.id.hasPrefix("/") ? file.id : "/\(file.id)") : file.remotePath
            itemName = newName ?? file.name
            isDirectory = false
            fileSize = file.size
        } else if let directory = dirRecord {
            sourcePath = directory.remotePath.isEmpty ? (directory.id.hasPrefix("/") ? directory.id : "/\(directory.id)") : directory.remotePath
            itemName = newName ?? directory.name
            isDirectory = true
        } else {
            sourcePath = itemId.hasPrefix("/") ? itemId : "/\(itemId)"
            itemName = newName ?? URL(fileURLWithPath: itemId).lastPathComponent
            if let meta = syncManager.getMetadata(fileId: itemId) {
                isDirectory = meta.isDirectory
            } else {
                isDirectory = itemId.hasSuffix("/")
            }
        }
        
        let destinationPath: String
        if let parent = try? database.getDirectory(id: newParentId) {
            let parentPath = parent.remotePath.isEmpty ? (parent.id.hasPrefix("/") ? parent.id : "/\(parent.id)") : parent.remotePath
            if parentPath == "/" || parentPath == rootId || parentPath.isEmpty {
                destinationPath = rootChildPath(itemName)
            } else {
                let trimmed = parentPath.hasSuffix("/") ? String(parentPath.dropLast()) : parentPath
                destinationPath = "\(trimmed)/\(itemName)"
            }
        } else {
            if newParentId == rootId || newParentId == "/" {
                destinationPath = rootChildPath(itemName)
            } else {
                let cleanParent = newParentId.hasPrefix("/") ? newParentId : "/\(newParentId)"
                let trimmed = cleanParent.hasSuffix("/") ? String(cleanParent.dropLast()) : cleanParent
                destinationPath = "\(trimmed)/\(itemName)"
            }
        }
        
        let opId = operationManager.addOperation(type: .move, fileName: itemName, filePath: destinationPath)
        var queuedMove = false
        let wasCached = cacheManager.isCached(fileId: itemId)
        let isPending = syncManager.hasPendingUpload(fileId: itemId) || itemId.hasPrefix("pending_") || (syncManager.getMetadata(fileId: itemId)?.syncStatus == .pendingUpload)
        if isPending {
            syncManager.updatePendingOperation(oldFileId: itemId, newFileId: destinationPath, newRemotePath: destinationPath, newName: itemName, newParentId: newParentId, sourceRemotePath: sourcePath)
        } else {
            do {
                operationManager.updateOperation(id: opId, status: .inProgress)
                try await storageClient.move(from: sourcePath, to: destinationPath)
            } catch {
                guard VFSOperationErrorPolicy.permitsOfflineRetry(error) else { throw error }
                try syncManager.enqueuePersistent(.move(itemId: destinationPath, sourceRemotePath: sourcePath, targetRemotePath: destinationPath), startProcessing: false)
                queuedMove = true
            }
        }
        
        let newFileId = destinationPath
        let targetSyncStatus: SyncStatus
        if isDirectory {
            try? database.moveDirectory(oldId: itemId, newId: newFileId, newName: itemName, newParentId: newParentId, newRemotePath: destinationPath)
            cacheManager.moveDirectoryCache(from: itemId, to: newFileId)
            syncManager.moveDirectoryMetadata(from: itemId, to: newFileId, newParentId: newParentId, newName: itemName, newRemotePath: destinationPath)
            targetSyncStatus = queuedMove ? .pendingMove : (isPending ? .pendingUpload : .synced)
            if var metadata = syncManager.getMetadata(fileId: newFileId) {
                metadata.syncStatus = targetSyncStatus
                syncManager.updateMetadata(metadata)
            }
        } else {
            try? database.deleteFile(id: itemId)
            try? database.insertFile(id: newFileId, name: itemName, parentId: newParentId, size: fileSize, encryptedName: itemName, remotePath: destinationPath)
            if cacheManager.isCached(fileId: itemId) {
                try? cacheManager.moveCache(from: itemId, to: newFileId)
            }
            let oldMeta = syncManager.getMetadata(fileId: itemId)
            targetSyncStatus = queuedMove ? .pendingMove : (isPending ? .pendingUpload : (wasCached ? .synced : (oldMeta?.syncStatus ?? .cloudOnly)))
            syncManager.moveMetadata(
                from: itemId,
                to: newFileId,
                newParentId: newParentId,
                newName: itemName,
                newRemotePath: destinationPath,
                fallbackStatus: targetSyncStatus
            )
        }
        operationManager.updateOperation(id: opId, status: queuedMove || isPending ? .pending : .completed)
        if queuedMove { syncManager.processSyncQueue() }
        
        return VirtualFileItem(
            id: newFileId,
            name: itemName,
            isDirectory: isDirectory,
            size: fileSize,
            modifiedAt: Date(),
            parentId: newParentId,
            syncStatus: targetSyncStatus,
            remotePath: destinationPath
        )
    }
    
    // MARK: - 复制
    
    public func copyItem(itemId: String, newParentId: String, newName: String? = nil) async throws -> VirtualFileItem {
        let sourcePath: String
        let itemName: String
        let isDirectory: Bool
        var fileSize: Int64 = 0
        
        var fileRecord = try? database.getFile(id: itemId)
        if fileRecord == nil && !itemId.hasPrefix("/") {
            fileRecord = try? database.getFile(id: "/\(itemId)")
        }
        var dirRecord = try? database.getDirectory(id: itemId)
        if dirRecord == nil && !itemId.hasPrefix("/") {
            dirRecord = try? database.getDirectory(id: "/\(itemId)")
        }
        
        if let file = fileRecord {
            sourcePath = file.remotePath.isEmpty ? (file.id.hasPrefix("/") ? file.id : "/\(file.id)") : file.remotePath
            itemName = newName ?? file.name
            isDirectory = false
            fileSize = file.size
        } else if let directory = dirRecord {
            sourcePath = directory.remotePath.isEmpty ? (directory.id.hasPrefix("/") ? directory.id : "/\(directory.id)") : directory.remotePath
            itemName = newName ?? directory.name
            isDirectory = true
        } else {
            sourcePath = itemId.hasPrefix("/") ? itemId : "/\(itemId)"
            itemName = newName ?? URL(fileURLWithPath: itemId).lastPathComponent
            if let meta = syncManager.getMetadata(fileId: itemId) {
                isDirectory = meta.isDirectory
            } else {
                isDirectory = itemId.hasSuffix("/")
            }
        }
        
        let destinationPath: String
        if let parent = try? database.getDirectory(id: newParentId) {
            let parentPath = parent.remotePath.isEmpty ? (parent.id.hasPrefix("/") ? parent.id : "/\(parent.id)") : parent.remotePath
            if parentPath == "/" || parentPath == rootId || parentPath.isEmpty {
                destinationPath = rootChildPath(itemName)
            } else {
                let trimmed = parentPath.hasSuffix("/") ? String(parentPath.dropLast()) : parentPath
                destinationPath = "\(trimmed)/\(itemName)"
            }
        } else {
            if newParentId == rootId || newParentId == "/" {
                destinationPath = rootChildPath(itemName)
            } else {
                let cleanParent = newParentId.hasPrefix("/") ? newParentId : "/\(newParentId)"
                let trimmed = cleanParent.hasSuffix("/") ? String(cleanParent.dropLast()) : cleanParent
                destinationPath = "\(trimmed)/\(itemName)"
            }
        }
        
        try await storageClient.copy(from: sourcePath, to: destinationPath)
        let newFileId = destinationPath
        let wasCached = cacheManager.isCached(fileId: itemId)
        
        if isDirectory {
            try? database.insertDirectory(
                id: newFileId,
                name: itemName,
                parentId: newParentId,
                encryptedId: itemName,
                remotePath: destinationPath
            )
            
            func duplicateChildren(from sourceParent: String, to targetParent: String) {
                if let children = try? database.listChildren(parentId: sourceParent) {
                    for child in children {
                        let childTargetId = "\(targetParent)/\(child.name)"
                        if child.isDirectory {
                            try? database.insertDirectory(id: childTargetId, name: child.name, parentId: targetParent, encryptedId: child.name, remotePath: childTargetId)
                            syncManager.updateMetadata(FileMetadata(fileId: childTargetId, name: child.name, parentId: targetParent, isDirectory: true, syncStatus: .synced, remotePath: childTargetId, localModifiedAt: Date(), remoteModifiedAt: Date()))
                            duplicateChildren(from: child.id, to: childTargetId)
                        } else {
                            try? database.insertFile(id: childTargetId, name: child.name, parentId: targetParent, size: child.size, encryptedName: child.name, remotePath: childTargetId)
                            if cacheManager.isCached(fileId: child.id) {
                                try? cacheManager.cloneCache(from: child.id, to: childTargetId)
                            }
                            let childStatus: SyncStatus = cacheManager.isCached(fileId: child.id) ? .synced : .cloudOnly
                            syncManager.updateMetadata(FileMetadata(fileId: childTargetId, name: child.name, parentId: targetParent, isDirectory: false, syncStatus: childStatus, localPath: cacheManager.isCached(fileId: child.id) ? cacheManager.localPath(for: childTargetId).path : nil, remotePath: childTargetId, size: child.size, localModifiedAt: Date(), remoteModifiedAt: Date()))
                        }
                    }
                }
            }
            duplicateChildren(from: itemId, to: newFileId)
        } else {
            try? database.insertFile(id: newFileId, name: itemName, parentId: newParentId, size: fileSize, encryptedName: itemName, remotePath: destinationPath)
            if wasCached {
                try? cacheManager.cloneCache(from: itemId, to: newFileId)
            }
        }
        
        let targetSyncStatus: SyncStatus = wasCached ? .synced : .cloudOnly
        syncManager.updateMetadata(FileMetadata(
            fileId: newFileId,
            name: itemName,
            parentId: newParentId,
            isDirectory: isDirectory,
            syncStatus: targetSyncStatus,
            localPath: wasCached ? cacheManager.localPath(for: newFileId).path : nil,
            remotePath: destinationPath,
            size: fileSize,
            localModifiedAt: Date(),
            remoteModifiedAt: Date()
        ))
        
        return VirtualFileItem(
            id: newFileId,
            name: itemName,
            isDirectory: isDirectory,
            size: fileSize,
            modifiedAt: Date(),
            parentId: newParentId,
            syncStatus: targetSyncStatus,
            remotePath: destinationPath
        )
    }
    
    // MARK: - 修改
    
    public func modifyFile(fileId: String, newContent: URL) async throws -> VirtualFileItem {
        let file = try database.getFile(id: fileId)
        let previous = syncManager.getMetadata(fileId: fileId)
        let remotePath = file?.remotePath ?? fileId
        let fileName = file?.name ?? URL(fileURLWithPath: fileId).lastPathComponent
        let parentId = file?.parentId ?? URL(fileURLWithPath: fileId).deletingLastPathComponent().path
        let fileSize = (try FileManager.default.attributesOfItem(atPath: newContent.path)[.size] as? NSNumber)?.int64Value ?? 0
        var metadata = previous ?? FileMetadata(fileId: fileId, name: fileName, parentId: parentId, isDirectory: false, syncStatus: .pendingUpload)
        metadata.syncStatus = .pendingUpload
        metadata.localPath = cacheManager.localPath(for: fileId).path
        metadata.remotePath = remotePath
        metadata.size = fileSize
        metadata.localModifiedAt = Date()
        syncManager.updateMetadata(metadata)
        try cacheManager.cacheFile(fileId: fileId, from: newContent)
        do {
            if storageClient.requiresETagForUpdate && metadata.etag == nil {
                throw StorageError.notSupported("Download the current revision before replacing a WebDAV file without a saved ETag")
            }
            metadata.etag = try await storageClient.uploadFile(localURL: cacheManager.localPath(for: fileId), to: remotePath, expectedETag: metadata.etag) { _ in }
            metadata.syncStatus = .synced
            metadata.remoteModifiedAt = Date()
            metadata.lastSyncTime = Date()
            try database.insertFile(id: fileId, name: fileName, parentId: parentId, size: fileSize, encryptedName: fileName, remotePath: remotePath, modifiedAt: metadata.localModifiedAt)
            syncManager.updateMetadata(metadata)
        } catch {
            if (error as? StorageError)?.isPreconditionFailure == true {
                metadata.syncStatus = .conflict
                syncManager.updateMetadata(metadata)
            }
            throw error
        }
        return VirtualFileItem(id: fileId, name: fileName, isDirectory: false, size: fileSize, modifiedAt: metadata.localModifiedAt!, parentId: parentId, syncStatus: .synced, localPath: metadata.localPath, remotePath: remotePath, etag: metadata.etag)
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
    
    private func rootChildPath(_ name: String) -> String {
        storagePath == "/" || storagePath.isEmpty ? "/\(name)" : "/" + storagePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + name
    }

    private func insertItemIntoDatabase(_ item: VirtualFileItem) throws {
            if item.isDirectory {
                try database.insertDirectory(id: item.id, name: item.name, parentId: item.parentId, encryptedId: item.name, remotePath: item.remotePath ?? "", modifiedAt: item.modifiedAt)
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
