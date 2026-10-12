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
import Darwin
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
    public var storageCapabilities: StorageCapabilities { storageClient.capabilities }
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
                        try database.insertDirectory(id: item.id, name: item.name, parentId: item.parentId, encryptedId: item.id, remotePath: item.remotePath ?? "", modifiedAt: item.modifiedAt)
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
        try await uploadFile(localURL: localURL, name: name, parentId: parentId, expectedETag: expectedETag, progress: nil)
    }

    public func uploadFile(localURL: URL, name: String, parentId: String, expectedETag: String?, progress: ((Double) -> Void)?) async throws -> VirtualFileItem {
        let parentDirId = cryptomatorFormat.dirIdData(from: parentId)
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
        let parentDirId = cryptomatorFormat.dirIdData(from: parentId)
        let item: VirtualFileItem
        do {
            item = try await cryptomatorFormat.uploadFile(localURL: localURL, name: name, parentDirId: parentDirId, mode: mode, progress: progress)
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
        _ = try await downloadFile(fileId: fileId, to: destinationURL, expectedETag: nil, progress: progress)
    }

    public func downloadFile(fileId: String, to destinationURL: URL, expectedETag: String?, progress: ((Double) -> Void)? = nil) async throws -> String? {
        var file = try? database.getFile(id: fileId)
        if file == nil && !fileId.hasPrefix("file_") {
            file = try? database.getFile(id: "file_\(fileId)")
        }
        guard let file = file else {
            throw VFSError.fileNotFound
        }
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destinationURL.deletingLastPathComponent().appendingPathComponent("download-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let deliveredETag = try await cryptomatorFormat.downloadFile(remotePath: file.remotePath, to: temporary, expectedETag: expectedETag, progress: progress)
        try syncManager.withJournalCommit {
            var metadata = try syncManager.getMetadataPersistent(fileId: file.id) ?? FileMetadata(fileId: file.id, name: file.name, parentId: file.parentId, isDirectory: false, syncStatus: .synced)
            let pending = try syncManager.queue.itemsForFilePersistent(fileId: file.id)
            let protectsEdit = metadata.syncStatus.protectsLocalChanges || !pending.isEmpty
            if protectsEdit && (metadata.localPath == destinationURL.path || cacheManager.localPath(for: file.id).standardizedFileURL == destinationURL.standardizedFileURL) {
                throw SyncError.operationFailed("A newer local edit arrived during download")
            }
            guard rename(temporary.path, destinationURL.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if !protectsEdit {
                metadata.etag = deliveredETag
                metadata.remotePath = file.remotePath
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
        var file = try? database.getFile(id: fileId)
        if file == nil && !fileId.hasPrefix("file_") {
            file = try? database.getFile(id: "file_\(fileId)")
        }
        guard let file = file else {
            throw VFSError.fileNotFound
        }
        let totalCipherSize = CryptomatorRandomAccess.calculateCiphertextSize(cleartextSize: file.size)
        return try await cryptomatorFormat.readCleartextRange(
            remotePath: file.remotePath,
            cleartextRange: range,
            totalCiphertextSize: totalCipherSize, expectedETag: expectedETag
        )
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
        let deletionMetadata = try syncManager.getMetadataPersistent(fileId: itemId)
        if deletionMetadata?.syncStatus != .localOnly {
            let revision = isDir ? StorageContentVerification.collectionDeletionETag(deletionMetadata?.remoteETag ?? deletionMetadata?.etag) : try StorageContentVerification.mutationETag(deletionMetadata?.remoteETag ?? deletionMetadata?.etag, required: storageClient.requiresETagForUpdate)
            try await cryptomatorFormat.deleteItem(remotePath: remotePath, dirIdData: dirIdData, expectedETag: revision)
        }
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
            
            if newRemotePath == file.remotePath {
                guard let unchanged = try getItem(id: file.id) else { throw VFSError.itemNotFound }
                return unchanged
            }
            var queuedMove = false
            var movedRevision: String? = nil
            let oldMeta = try syncManager.getMetadataPersistent(fileId: file.id)
            let isLocalOnly = (oldMeta?.syncStatus == .localOnly) || finalName.hasSuffix(".nosync")
            let isPending = syncManager.hasPendingUpload(fileId: file.id) || file.id.hasPrefix("pending_") || (oldMeta?.syncStatus == .pendingUpload)
            if isLocalOnly {
                Logger.shared.info(.sync, "EncryptedVFS moveItem: Item is localOnly / .nosync, skipping remote storageClient.move")
            } else if isPending {
                syncManager.updatePendingOperation(oldFileId: file.id, newFileId: newFileId, newRemotePath: newRemotePath, newName: finalName, newParentId: newParentId, sourceRemotePath: file.remotePath)
            } else {
                do {
                    let revision = try StorageContentVerification.mutationETag(oldMeta?.remoteETag ?? oldMeta?.etag, required: storageClient.requiresETagForUpdate)
                    
                    if isShortened, let sDir = shortenedDirPath {
                        if (try? await storageClient.exists(path: sDir)) != true {
                            try await storageClient.createDirectory(path: sDir)
                        }
                        let tempNameURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        defer { try? FileManager.default.removeItem(at: tempNameURL) }
                        if let encData = newEncName.data(using: .utf8) {
                            try encData.write(to: tempNameURL)
                            _ = try await storageClient.uploadFile(localURL: tempNameURL, to: "\(sDir)/name.c9s", mode: .createIfAbsent) { _ in }
                            try? FileManager.default.removeItem(at: tempNameURL)
                        }
                        movedRevision = try await storageClient.moveWithRevision(from: file.remotePath, to: newRemotePath, expectedETag: revision)
                    } else {
                        let newParentDirPath = try cryptomatorFormat.getDirPath(dirId: newParentDirId)
                        if (try? await storageClient.exists(path: newParentDirPath)) != true {
                            try await storageClient.createDirectory(path: newParentDirPath)
                        }
                        movedRevision = try await storageClient.moveWithRevision(from: file.remotePath, to: newRemotePath, expectedETag: revision)
                    }
                } catch {
                    guard VFSOperationErrorPolicy.permitsOfflineRetry(error) else { throw error }
                    try syncManager.enqueuePersistent(.move(itemId: newFileId, sourceRemotePath: file.remotePath, targetRemotePath: newRemotePath), startProcessing: false, expectedETag: oldMeta?.remoteETag ?? oldMeta?.etag)
                    queuedMove = true
                }
            }
            
            try? database.deleteFile(id: file.id)
            try database.insertFile(
                id: newFileId,
                name: finalName,
                parentId: newParentId,
                size: file.size,
                encryptedName: finalName,
                remotePath: newRemotePath
            )
            ItemAliasStore.shared.recordAlias(from: file.id, to: newFileId)
            
            let wasCached = cacheManager.isCached(fileId: file.id)
            if wasCached {
                try? cacheManager.moveCache(from: file.id, to: newFileId)
            }
            
            let targetSyncStatus: SyncStatus = isLocalOnly ? .localOnly : (queuedMove ? .pendingMove : (isPending ? .pendingUpload : (wasCached ? .synced : (oldMeta?.syncStatus ?? .cloudOnly))))
            syncManager.moveMetadata(
                from: file.id,
                to: newFileId,
                newParentId: newParentId,
                newName: finalName,
                newRemotePath: newRemotePath,
                fallbackStatus: targetSyncStatus
            )
                if var metadata = try syncManager.getMetadataPersistent(fileId: newFileId) {
                    let oldCachePath = cacheManager.localPath(for: file.id).path
                    if metadata.localPath == oldCachePath && cacheManager.isCached(fileId: newFileId) {
                        metadata.localPath = cacheManager.localPath(for: newFileId).path
                    }
                    if let tag = try? StorageContentVerification.mutationETag(movedRevision, required: true) {
                        metadata.remoteETag = tag
                        if oldMeta?.syncStatus == .synced && oldMeta?.etag == (oldMeta?.remoteETag ?? oldMeta?.etag) { metadata.etag = tag }
                    }
                    try syncManager.updateMetadataPersistent(metadata)
                }
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
            if storageClient.requiresETagForUpdate {
                throw StorageError.serverError(statusCode: 412, message: "Encrypted directory moves require a version-bound pointer transaction")
            }
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
                if newParentId != dir.parentId {
                    let dirIdData = cryptomatorFormat.dirIdData(from: dir.id)
                    await cryptomatorFormat.updateDirectoryParentId(dirIdData: dirIdData, newParentDirId: newParentDirId)
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
        try await copyItemInternal(itemId: itemId, newParentId: newParentId, newName: newName, cachedContentOverride: nil, expectedSourceETag: nil)
    }
    public func copyItem(itemId: String, newParentId: String, newName: String?, cachedContentOverride: String, expectedSourceETag: String) async throws -> VirtualFileItem {
        try await copyItemInternal(itemId: itemId, newParentId: newParentId, newName: newName, cachedContentOverride: cachedContentOverride, expectedSourceETag: expectedSourceETag)
    }
    private func copyItemInternal(itemId: String, newParentId: String, newName: String?, cachedContentOverride: String?, expectedSourceETag: String?) async throws -> VirtualFileItem {
        var fileRecord = try? database.getFile(id: itemId)
        if fileRecord == nil && !itemId.hasPrefix("file_") {
            fileRecord = try? database.getFile(id: "file_\(itemId)")
        }
        
        if let file = fileRecord {
            let finalName = newName ?? file.name
            let newParentDirId = cryptomatorFormat.dirIdData(from: newParentId)
            let (newRemotePath, isShortened, newEncName, shortenedDirPath) = try cryptomatorFormat.getFileRemotePath(name: finalName, parentDirId: newParentDirId)
            let newFileId = "file_\(newEncName)"
            guard newRemotePath != file.remotePath else { throw StorageError.serverError(statusCode: 400, message: "Cannot copy an item onto itself") }
            let sourceMetadata = try syncManager.getMetadataPersistent(fileId: file.id)
            if let expectedSourceETag {
                guard sourceMetadata?.syncStatus == .synced,
                      sourceMetadata?.etag == expectedSourceETag,
                      (sourceMetadata?.remoteETag ?? sourceMetadata?.etag) == expectedSourceETag,
                      !syncManager.hasPendingOperation(fileId: file.id) else {
                    throw StorageError.serverError(statusCode: 412, message: "Cached COPY source revision changed")
                }
            }
            if sourceMetadata?.syncStatus.protectsLocalChanges == true || syncManager.hasPendingOperation(fileId: file.id) {
                let local = try VFSLocalCopy.prepare(sourceId: file.id, targetId: newFileId, name: finalName, parentId: newParentId,
                    remotePath: newRemotePath, encrypted: true, vaultId: vaultId, sync: syncManager, cache: cacheManager)
                try database.insertFile(id: local.id, name: finalName, parentId: newParentId, size: local.size, encryptedName: finalName, remotePath: newRemotePath)
                return local
            }
            let revision = try StorageContentVerification.mutationETag(sourceMetadata?.remoteETag ?? sourceMetadata?.etag, required: storageClient.requiresETagForUpdate)
            try syncManager.withJournalCommit {
                guard try syncManager.getMetadataPersistent(fileId: newFileId) == nil,
                      !syncManager.hasPendingOperation(fileId: newFileId),
                      !cacheManager.isCached(fileId: newFileId) else {
                    throw StorageError.serverError(statusCode: 412, message: "COPY destination has local state")
                }
            }
            try await storageClient.createDirectory(path: cryptomatorFormat.getDirPath(dirId: newParentDirId))
            if isShortened, let directory = shortenedDirPath {
                try await storageClient.createDirectory(path: directory)
                let nameURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: nameURL) }
                try Data(newEncName.utf8).write(to: nameURL)
                _ = try await storageClient.uploadFile(localURL: nameURL, to: directory + "/name.c9s", mode: .createIfAbsent) { _ in }
            }
            let returnedETag = try await storageClient.copy(from: file.remotePath, to: newRemotePath, expectedETag: revision)
            let committedETag = try? StorageContentVerification.mutationETag(returnedETag, required: true)
            
            return try syncManager.withJournalCommit {
                guard try syncManager.getMetadataPersistent(fileId: newFileId) == nil,
                      !syncManager.hasPendingOperation(fileId: newFileId),
                          !cacheManager.isCached(fileId: newFileId) else {
                    throw StorageError.serverError(statusCode: 412, message: "COPY destination changed during the request")
                }
                let currentSource = try syncManager.getMetadataPersistent(fileId: file.id)
                let sourceUnchanged = currentSource?.syncStatus == sourceMetadata?.syncStatus
                    && currentSource?.etag == sourceMetadata?.etag && currentSource?.remoteETag == sourceMetadata?.remoteETag
                    && currentSource?.localModifiedAt == sourceMetadata?.localModifiedAt && currentSource?.localPath == sourceMetadata?.localPath
                    && !syncManager.hasPendingOperation(fileId: file.id)
                try database.insertFile(
                    id: newFileId,
                    name: finalName,
                    parentId: newParentId,
                    size: file.size,
                    encryptedName: finalName,
                    remotePath: newRemotePath
                )
                
                let wasCached = (cachedContentOverride != nil || sourceUnchanged) && committedETag != nil && sourceMetadata?.syncStatus == .synced && (cachedContentOverride != nil || sourceMetadata?.lastSyncTime != nil) && sourceMetadata?.etag == revision && cacheManager.isCached(fileId: cachedContentOverride ?? file.id)
                var cacheCloned = false
                if wasCached {
                    do {
                        try cacheManager.cloneCache(from: cachedContentOverride ?? file.id, to: newFileId, confirmedETag: committedETag)
                        cacheCloned = true
                    } catch { cacheCloned = false }
                }
                let targetSyncStatus: SyncStatus = cacheCloned ? .synced : .cloudOnly
                try syncManager.updateMetadataPersistent(FileMetadata(
                    fileId: newFileId,
                    name: finalName,
                    parentId: newParentId,
                    isDirectory: false,
                    syncStatus: targetSyncStatus,
                    localPath: cacheCloned ? cacheManager.localPath(for: newFileId).path : nil,
                    remotePath: newRemotePath,
                    size: file.size,
                    localModifiedAt: Date(),
                    remoteModifiedAt: Date(), etag: committedETag, remoteETag: committedETag,
                    downloadProgress: cacheCloned ? 1 : 0, lastSyncTime: cacheCloned ? Date() : nil
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
            }
        } else if let dir = try? database.getDirectory(id: itemId) {
            var ancestor = newParentId
            var visited = Set<String>()
            while visited.insert(ancestor).inserted {
                guard ancestor != itemId else { throw StorageError.serverError(statusCode: 400, message: "Cannot copy a directory into itself") }
                guard let parent = try database.getDirectory(id: ancestor), let nextParent = parent.parentId, nextParent != ancestor else { break }
                ancestor = nextParent
            }
            for id in [itemId] + database.getAllDescendantFileIds(directoryId: itemId) {
                if (try syncManager.getMetadataPersistent(fileId: id))?.syncStatus.protectsLocalChanges == true || syncManager.hasPendingOperation(fileId: id) {
                    throw StorageError.notSupported("Synchronize pending directory edits before copying the directory")
                }
            }
            // Snapshot before creating the destination so enumeration cannot recurse
            // into a newly created child of the source.
            let children = try await listDirectoryFromRemoteAsync(directoryId: itemId)
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
            let item = try await cryptomatorFormat.uploadFile(localURL: cacheManager.localPath(for: file.id), name: file.name, parentDirId: cryptomatorFormat.dirIdData(from: file.parentId), mode: metadata.etag.map { .replace(expectedETag: $0) } ?? .createIfAbsent)
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
