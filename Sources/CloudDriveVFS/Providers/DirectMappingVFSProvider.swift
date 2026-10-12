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
import Darwin
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
    public var storageCapabilities: StorageCapabilities { storageClient.capabilities }
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
                let isCached = cacheManager.isCached(fileId: file.id)
                let meta = syncManager.getMetadata(fileId: file.id)
                let effectiveStatus: SyncStatus
                if let meta = meta {
                    effectiveStatus = meta.syncStatus
                } else {
                    effectiveStatus = .cloudOnly
                }
                return VirtualFileItem(
                    id: file.id,
                    name: file.name,
                    isDirectory: false,
                    size: file.size,
                    modifiedAt: file.modifiedAt,
                    parentId: file.parentId,
                    syncStatus: effectiveStatus,
                    localPath: isCached ? cacheManager.localPath(for: file.id).path : meta?.localPath,
                    remotePath: file.remotePath.isEmpty ? file.id : file.remotePath,
                    etag: meta?.etag
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
        
        try syncManager.withJournalCommit {
            var metadataToBatch: [FileMetadata] = []
            try database.connection.withTransaction {
                for item in items {
                    let previous = try syncManager.getMetadataPersistent(fileId: item.id)
                    if previous?.syncStatus == .pendingDelete { continue }
                    if var protected = previous, protected.syncStatus.protectsLocalChanges {
                        protected.remoteModifiedAt = item.modifiedAt
                        protected.remoteETag = item.etag
                        metadataToBatch.append(protected)
                        continue
                    }
                    if item.isDirectory {
                        try database.insertDirectory(id: item.id, name: item.name, parentId: item.parentId, encryptedId: item.name, remotePath: item.remotePath ?? "", modifiedAt: item.modifiedAt)
                    } else {
                        try database.insertFile(id: item.id, name: item.name, parentId: item.parentId, size: item.size, encryptedName: item.name, remotePath: item.remotePath ?? "", modifiedAt: item.modifiedAt)
                    }
                    let isCached = !item.isDirectory && cacheManager.isCached(fileId: item.id)
                    var metadata = previous ?? FileMetadata(fileId: item.id, name: item.name, parentId: item.parentId,
                        isDirectory: item.isDirectory, syncStatus: item.isDirectory ? .synced : .cloudOnly,
                        remotePath: item.remotePath, size: item.size, remoteModifiedAt: item.modifiedAt, remoteETag: item.etag)
                    metadata.remotePath = item.remotePath
                    metadata.remoteModifiedAt = item.modifiedAt
                    metadata.remoteETag = item.etag
                    if !item.isDirectory {
                        let etagMismatched = metadata.etag != nil && item.etag != nil && metadata.etag != item.etag
                        let confirmed = isCached && !etagMismatched
                        metadata.syncStatus = confirmed ? .synced : .cloudOnly
                        metadata.downloadProgress = confirmed ? 1 : 0
                        if confirmed { metadata.localPath = cacheManager.localPath(for: item.id).path }
                        if !isCached { metadata.size = item.size }
                    }
                    metadataToBatch.append(metadata)
                }
            }
            if !metadataToBatch.isEmpty { try syncManager.updateMetadataBatchPersistent(metadataToBatch) }
        }

        directoryCacheLock.lock()
        directoryCacheTimestamps[directoryId] = Date()
        directoryCacheLock.unlock()
        
        var mergedItems = items.compactMap { item -> VirtualFileItem? in
            if let meta = syncManager.getMetadata(fileId: item.id), meta.syncStatus == .pendingDelete {
                return nil
            }
            var localItem = previousItems.first(where: { $0.id == item.id }) ?? item
            if let metadata = syncManager.getMetadata(fileId: item.id) {
                localItem.syncStatus = metadata.syncStatus
                localItem.etag = metadata.etag
                localItem.localPath = metadata.localPath
            }
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
        try await uploadFile(localURL: localURL, name: name, parentId: parentId, expectedETag: expectedETag, progress: nil)
    }

    public func uploadFile(localURL: URL, name: String, parentId: String, expectedETag: String?, progress: ((Double) -> Void)?) async throws -> VirtualFileItem {
        let mode: StorageWriteMode
        if let etag = expectedETag {
            mode = .replace(expectedETag: etag)
        } else {
            mode = .createIfAbsent
        }
        return try await uploadFile(localURL: localURL, name: name, parentId: parentId, mode: mode, progress: progress)
    }

    public func uploadFile(localURL: URL, name: String, parentId: String, mode: StorageWriteMode) async throws -> VirtualFileItem {
        try await uploadFile(localURL: localURL, name: name, parentId: parentId, mode: mode, progress: nil)
    }

    public func uploadFile(localURL: URL, name: String, parentId: String, mode: StorageWriteMode, progress: ((Double) -> Void)?) async throws -> VirtualFileItem {
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
                progress?(p)
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
        _ = try await downloadFile(fileId: fileId, to: destinationURL, expectedETag: nil, progress: progress)
    }

    public func downloadFile(fileId: String, to destinationURL: URL, expectedETag: String?, progress: ((Double) -> Void)? = nil) async throws -> String? {
        let parentDir = destinationURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        
        let file = try database.getFile(id: fileId)
        let remotePath = file?.remotePath ?? fileId
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destinationURL.deletingLastPathComponent().appendingPathComponent("download-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let deliveredETag = try await storageClient.downloadFile(path: remotePath, to: temporary, expectedETag: expectedETag) { progress?($0) }
        try syncManager.withJournalCommit {
            var metadata = try syncManager.getMetadataPersistent(fileId: fileId) ?? FileMetadata(fileId: fileId, name: file?.name ?? destinationURL.lastPathComponent, parentId: file?.parentId ?? rootId, isDirectory: false, syncStatus: .synced)
            let pending = try syncManager.queue.itemsForFilePersistent(fileId: fileId)
            let protectsEdit = metadata.syncStatus.protectsLocalChanges || !pending.isEmpty
            if protectsEdit && (metadata.localPath == destinationURL.path || cacheManager.localPath(for: fileId).standardizedFileURL == destinationURL.standardizedFileURL) {
                throw SyncError.operationFailed("A newer local edit arrived during download")
            }
            guard rename(temporary.path, destinationURL.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if !protectsEdit {
                metadata.etag = deliveredETag
                metadata.remotePath = remotePath
                metadata.syncStatus = .synced
                metadata.localPath = destinationURL.path
                metadata.lastSyncTime = Date()
                try syncManager.updateMetadataPersistent(metadata)
            }
        }
        return deliveredETag
    }

    public func readRange(fileId: String, range: ClosedRange<Int64>) async throws -> Data {
        try await readRange(fileId: fileId, range: range, expectedETag: nil)
    }

    public func readRange(fileId: String, range: ClosedRange<Int64>, expectedETag: String?) async throws -> Data {
        let file = try database.getFile(id: fileId)
        let remotePath = file?.remotePath ?? fileId
        return try await storageClient.downloadRange(path: remotePath, range: range, expectedETag: expectedETag)
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
            
            let deletionMetadata = try syncManager.getMetadataPersistent(fileId: file.id)
            if deletionMetadata?.syncStatus != .localOnly {
                var baselineETag = deletionMetadata?.remoteETag ?? deletionMetadata?.etag
                if baselineETag == nil && storageClient.requiresETagForUpdate {
                    let parentRemotePath = (effectiveRemotePath as NSString).deletingLastPathComponent
                    let listPath = parentRemotePath.isEmpty ? "/" : parentRemotePath
                    if let resources = try? await storageClient.listDirectory(path: listPath) {
                        let targetName = (effectiveRemotePath as NSString).lastPathComponent
                        if let matched = resources.first(where: { $0.displayName == targetName || $0.path == effectiveRemotePath }) {
                            baselineETag = matched.etag
                        }
                    }
                }
                let revision = try StorageContentVerification.mutationETag(baselineETag, required: storageClient.requiresETagForUpdate)
                try await storageClient.delete(path: effectiveRemotePath, expectedETag: revision)
            }
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
            let metadata = try syncManager.getMetadataPersistent(fileId: directory.id)
            if metadata?.syncStatus != .localOnly {
                let revision = StorageContentVerification.collectionDeletionETag(metadata?.remoteETag ?? metadata?.etag)
                do { try await storageClient.delete(path: effectiveRemotePath, expectedETag: revision) }
                catch {
                    if revision == nil, StorageContentVerification.deletionOutcomeIsUncertain(error) {
                        throw StorageError.indeterminateMutation("Collection DELETE must be checked before retrying")
                    }
                    throw error
                }
            }
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
        let revision = try StorageContentVerification.mutationETag(try syncManager.getMetadataPersistent(fileId: itemId)?.etag, required: storageClient.requiresETagForUpdate)
        if storageClient.requiresETagForUpdate, (try syncManager.getMetadataPersistent(fileId: itemId))?.isDirectory != false {
            throw StorageError.serverError(statusCode: 412, message: "Unknown deletion target cannot be safely classified")
        }
        try await storageClient.delete(path: remotePath, expectedETag: revision)
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
        
        if sourcePath == destinationPath {
            guard let unchanged = try getItem(id: itemId) else { throw VFSError.itemNotFound }
            return unchanged
        }
        let opId = operationManager.addOperation(type: .move, fileName: itemName, filePath: destinationPath)
        var queuedMove = false
        var movedRevision: String? = nil
        let wasCached = cacheManager.isCached(fileId: itemId)
        let oldMeta = try syncManager.getMetadataPersistent(fileId: itemId)
        let isLocalOnly = (oldMeta?.syncStatus == .localOnly) || itemName.hasSuffix(".nosync")
        let isPending = syncManager.hasPendingUpload(fileId: itemId) || itemId.hasPrefix("pending_") || (oldMeta?.syncStatus == .pendingUpload)
        if isLocalOnly {
            Logger.shared.info(.sync, "DirectMappingVFS moveItem: Item is localOnly / .nosync, skipping remote storageClient.move")
        } else if isPending {
            syncManager.updatePendingOperation(oldFileId: itemId, newFileId: destinationPath, newRemotePath: destinationPath, newName: itemName, newParentId: newParentId, sourceRemotePath: sourcePath)
        } else {
            do {
                operationManager.updateOperation(id: opId, status: .inProgress)
                var baselineETag = oldMeta?.remoteETag ?? oldMeta?.etag
                if baselineETag == nil && storageClient.requiresETagForUpdate && !isDirectory {
                    let parentRemotePath = (sourcePath as NSString).deletingLastPathComponent
                    let listPath = parentRemotePath.isEmpty ? "/" : parentRemotePath
                    if let resources = try? await storageClient.listDirectory(path: listPath) {
                        let targetName = (sourcePath as NSString).lastPathComponent
                        if let matched = resources.first(where: { $0.displayName == targetName || $0.path == sourcePath }) {
                            baselineETag = matched.etag
                        }
                    }
                }
                let revision = try StorageContentVerification.mutationETag(baselineETag, required: !isDirectory && storageClient.requiresETagForUpdate)
                movedRevision = try await storageClient.moveWithRevision(from: sourcePath, to: destinationPath, expectedETag: revision)
            } catch {
                guard VFSOperationErrorPolicy.permitsOfflineRetry(error) else { throw error }
                try syncManager.enqueuePersistent(.move(itemId: destinationPath, sourceRemotePath: sourcePath, targetRemotePath: destinationPath), startProcessing: false, expectedETag: oldMeta?.remoteETag ?? oldMeta?.etag)
                queuedMove = true
            }
        }
        
        let newFileId = destinationPath
        let targetSyncStatus: SyncStatus
        if isDirectory {
            targetSyncStatus = isLocalOnly ? .localOnly : (queuedMove ? .pendingMove : (isPending ? .pendingUpload : .synced))
            try cacheManager.moveDirectoryCache(from: itemId, to: newFileId)
            try database.moveDirectory(oldId: itemId, newId: newFileId, newName: itemName, newParentId: newParentId, newRemotePath: destinationPath)
            syncManager.moveDirectoryMetadata(from: itemId, to: newFileId, newParentId: newParentId, newName: itemName, newRemotePath: destinationPath)
            ItemAliasStore.shared.recordAlias(from: itemId, to: newFileId)
            if var metadata = syncManager.getMetadata(fileId: newFileId) {
                metadata.syncStatus = targetSyncStatus
                syncManager.updateMetadata(metadata)
            }
        } else {
            try? database.deleteFile(id: itemId)
            try? database.insertFile(id: newFileId, name: itemName, parentId: newParentId, size: fileSize, encryptedName: itemName, remotePath: destinationPath)
            ItemAliasStore.shared.recordAlias(from: itemId, to: newFileId)
            if cacheManager.isCached(fileId: itemId) {
                try? cacheManager.moveCache(from: itemId, to: newFileId)
            }
            targetSyncStatus = isLocalOnly ? .localOnly : (queuedMove ? .pendingMove : (isPending ? .pendingUpload : (wasCached ? .synced : (oldMeta?.syncStatus ?? .cloudOnly))))
            syncManager.moveMetadata(
                from: itemId,
                to: newFileId,
                newParentId: newParentId,
                newName: itemName,
                newRemotePath: destinationPath,
                fallbackStatus: targetSyncStatus
            )
            if var metadata = try syncManager.getMetadataPersistent(fileId: newFileId) {
                let oldCachePath = cacheManager.localPath(for: itemId).path
                if metadata.localPath == oldCachePath && cacheManager.isCached(fileId: newFileId) {
                    metadata.localPath = cacheManager.localPath(for: newFileId).path
                }
                if let tag = try? StorageContentVerification.mutationETag(movedRevision, required: true) {
                    metadata.remoteETag = tag
                    if oldMeta?.syncStatus == .synced && oldMeta?.etag == (oldMeta?.remoteETag ?? oldMeta?.etag) { metadata.etag = tag }
                }
                try syncManager.updateMetadataPersistent(metadata)
            }
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
        try await copyItemInternal(itemId: itemId, newParentId: newParentId, newName: newName, cachedContentOverride: nil, expectedSourceETag: nil)
    }
    public func copyItem(itemId: String, newParentId: String, newName: String?, cachedContentOverride: String, expectedSourceETag: String) async throws -> VirtualFileItem {
        try await copyItemInternal(itemId: itemId, newParentId: newParentId, newName: newName, cachedContentOverride: cachedContentOverride, expectedSourceETag: expectedSourceETag)
    }
    private func copyItemInternal(itemId: String, newParentId: String, newName: String?, cachedContentOverride: String?, expectedSourceETag: String?) async throws -> VirtualFileItem {
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
        
        if destinationPath == sourcePath || (isDirectory && destinationPath.hasPrefix(sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/")) {
            throw StorageError.serverError(statusCode: 400, message: "Cannot copy an item onto itself or into its own descendants")
        }
        let sourceId = fileRecord?.id ?? dirRecord?.id ?? itemId
        let sourceMetadata = try syncManager.getMetadataPersistent(fileId: sourceId)
        if let expectedSourceETag {
            guard !isDirectory, sourceMetadata?.syncStatus == .synced,
                  sourceMetadata?.etag == expectedSourceETag,
                  (sourceMetadata?.remoteETag ?? sourceMetadata?.etag) == expectedSourceETag,
                  !syncManager.hasPendingOperation(fileId: sourceId) else {
                throw StorageError.serverError(statusCode: 412, message: "Cached COPY source revision changed")
            }
        }
        let dirty = sourceMetadata?.syncStatus.protectsLocalChanges == true || syncManager.hasPendingOperation(fileId: sourceId)
        if dirty {
            guard !isDirectory else { throw StorageError.notSupported("Synchronize pending directory edits before copying the directory") }
            let local = try VFSLocalCopy.prepare(sourceId: sourceId, targetId: destinationPath, name: itemName, parentId: newParentId,
                remotePath: destinationPath, encrypted: false, vaultId: vaultId, sync: syncManager, cache: cacheManager)
            try database.insertFile(id: local.id, name: itemName, parentId: newParentId, size: local.size, encryptedName: itemName, remotePath: destinationPath)
            return local
        }
        if isDirectory {
            // A single server COPY scales with directory size without downloading
            // payloads or duplicating every child cache in the client.
            for childId in database.getAllDescendantFileIds(directoryId: sourceId) {
                if (try syncManager.getMetadataPersistent(fileId: childId))?.syncStatus.protectsLocalChanges == true || syncManager.hasPendingOperation(fileId: childId) {
                    throw StorageError.notSupported("Synchronize pending descendant edits before copying the directory")
                }
            }
        }
        let revision = try StorageContentVerification.mutationETag(sourceMetadata?.remoteETag ?? sourceMetadata?.etag, required: storageClient.requiresETagForUpdate)
        try syncManager.withJournalCommit {
            guard try syncManager.getMetadataPersistent(fileId: destinationPath) == nil,
                  !syncManager.hasPendingOperation(fileId: destinationPath),
                  !cacheManager.isCached(fileId: destinationPath) else {
                throw StorageError.serverError(statusCode: 412, message: "COPY destination has local state")
            }
        }
        let returnedETag = try await storageClient.copy(from: sourcePath, to: destinationPath, expectedETag: revision)
        let committedETag = try? StorageContentVerification.mutationETag(returnedETag, required: true)
        return try syncManager.withJournalCommit {
            guard try syncManager.getMetadataPersistent(fileId: destinationPath) == nil,
                  !syncManager.hasPendingOperation(fileId: destinationPath),
                      !cacheManager.isCached(fileId: destinationPath) else {
                throw StorageError.serverError(statusCode: 412, message: "COPY destination changed during the request")
            }
            let currentSource = try syncManager.getMetadataPersistent(fileId: sourceId)
            let sourceUnchanged = currentSource?.syncStatus == sourceMetadata?.syncStatus
                && currentSource?.etag == sourceMetadata?.etag && currentSource?.remoteETag == sourceMetadata?.remoteETag
                && currentSource?.localModifiedAt == sourceMetadata?.localModifiedAt && currentSource?.localPath == sourceMetadata?.localPath
                && !syncManager.hasPendingOperation(fileId: sourceId)
            var cloned = false
            if (cachedContentOverride != nil || sourceUnchanged), !isDirectory, committedETag != nil, sourceMetadata?.syncStatus == .synced,
               (cachedContentOverride != nil || sourceMetadata?.lastSyncTime != nil), sourceMetadata?.etag == revision, cacheManager.isCached(fileId: cachedContentOverride ?? sourceId) {
                do {
                    try cacheManager.cloneCache(from: cachedContentOverride ?? sourceId, to: destinationPath, confirmedETag: committedETag)
                    cloned = true
                } catch { cloned = false }
            }
            if isDirectory { try database.insertDirectory(id: destinationPath, name: itemName, parentId: newParentId, encryptedId: itemName, remotePath: destinationPath) }
            else { try database.insertFile(id: destinationPath, name: itemName, parentId: newParentId, size: fileSize, encryptedName: itemName, remotePath: destinationPath) }
            let status: SyncStatus = isDirectory || cloned ? .synced : .cloudOnly
            let metadata = FileMetadata(fileId: destinationPath, name: itemName, parentId: newParentId, isDirectory: isDirectory,
                syncStatus: status, localPath: cloned ? cacheManager.localPath(for: destinationPath).path : nil,
                remotePath: destinationPath, size: fileSize, etag: committedETag, remoteETag: committedETag,
                downloadProgress: cloned ? 1 : 0, lastSyncTime: cloned ? Date() : nil)
            try syncManager.updateMetadataPersistent(metadata)
            return VirtualFileItem(id: destinationPath, name: itemName, isDirectory: isDirectory, size: fileSize,
                modifiedAt: Date(), parentId: newParentId, syncStatus: status, localPath: metadata.localPath,
                remotePath: destinationPath, etag: committedETag)
        }
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
            metadata.etag = try await storageClient.uploadFile(localURL: cacheManager.localPath(for: fileId), to: remotePath, mode: metadata.etag.map { .replace(expectedETag: $0) } ?? .createIfAbsent) { _ in }
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
        let isCached = !item.isDirectory && cacheManager.isCached(fileId: item.id)
        var metadata = syncManager.getMetadata(fileId: item.id) ?? FileMetadata(
            fileId: item.id,
            name: item.name,
            parentId: item.parentId,
            isDirectory: item.isDirectory,
            syncStatus: (item.isDirectory || isCached) ? .synced : .cloudOnly,
            localPath: isCached ? cacheManager.localPath(for: item.id).path : nil,
            remotePath: item.remotePath,
            size: item.size,
            localModifiedAt: item.modifiedAt,
            remoteModifiedAt: item.modifiedAt,
            etag: item.etag,
            downloadProgress: (item.isDirectory || isCached) ? 1.0 : 0.0,
            lastSyncTime: isCached ? Date() : nil
        )
        metadata.remotePath = item.remotePath
        metadata.remoteModifiedAt = item.modifiedAt
        if isCached && metadata.syncStatus == .cloudOnly {
            metadata.syncStatus = .synced
            metadata.downloadProgress = 1.0
            if metadata.localPath == nil {
                metadata.localPath = cacheManager.localPath(for: item.id).path
            }
        }
        if !isCached && !metadata.syncStatus.protectsLocalChanges {
            metadata.etag = item.etag
            metadata.size = item.size
        }
        syncManager.updateMetadata(metadata)
    }
}
