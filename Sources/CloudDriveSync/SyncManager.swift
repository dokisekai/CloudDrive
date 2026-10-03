//
//  SyncManager.swift
//  CloudDriveSync
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  文件同步管理器 - 向后兼容门面，委托至 SyncService
//

import Foundation
import CloudDriveContracts
import Network

/// 文件同步管理器 (兼容旧 API 的门面)
public class SyncManager {
    public static let shared = SyncManager()
    private static let registryLock = NSLock()
    private static var scopedManagers: [String: SyncManager] = [:]

    public static func forVault(_ vaultId: String) -> SyncManager {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let manager = scopedManagers[vaultId] { return manager }
        let manager = SyncManager(service: SyncService(vaultId: vaultId))
        scopedManagers[vaultId] = manager
        return manager
    }

    public var vaultId: String? { service.vaultId }
    
    private let service: SyncService
    
    public var activeVFS: (any SyncVaultAccess)? {
        get { service.activeVFS }
        set { service.activeVFS = newValue }
    }
    
    public init(service: SyncService = SyncService.shared) {
        self.service = service
    }
    
    // MARK: - 配置
    
    public func configure(storageClient: StorageClient, vfs: (any SyncVaultAccess)? = nil) {
        service.configure(storageClient: storageClient, vfs: vfs)
    }
    
    public func getStorageClient() -> StorageClient? {
        return service.getStorageClient()
    }
    
    // MARK: - 网络监控
    
    public func getNetworkStatus() -> NetworkStatus {
        return service.getNetworkStatus()
    }
    
    // MARK: - 元数据管理
    
    public func updateMetadata(_ metadata: FileMetadata) {
        service.updateMetadata(metadata)
    }

    public func updateMetadataPersistent(_ metadata: FileMetadata) throws {
        try service.metadataStore.updateMetadataPersistent(metadata)
    }
    
    public func getMetadata(fileId: String) -> FileMetadata? {
        return service.getMetadata(fileId: fileId)
    }
    
    public func getAllMetadata() -> [FileMetadata] {
        return service.getAllMetadata()
    }
    
    public func removeMetadata(fileId: String) {
        service.removeMetadata(fileId: fileId)
    }
    
    public func moveMetadata(
        from oldFileId: String,
        to newFileId: String,
        newParentId: String,
        newName: String,
        newRemotePath: String,
        fallbackStatus: SyncStatus
    ) {
        service.moveMetadata(
            from: oldFileId,
            to: newFileId,
            newParentId: newParentId,
            newName: newName,
            newRemotePath: newRemotePath,
            fallbackStatus: fallbackStatus
        )
    }
    
    public func moveDirectoryMetadata(
        from oldDirId: String,
        to newDirId: String,
        newParentId: String,
        newName: String,
        newRemotePath: String
    ) {
        service.moveDirectoryMetadata(
            from: oldDirId,
            to: newDirId,
            newParentId: newParentId,
            newName: newName,
            newRemotePath: newRemotePath
        )
    }
    
    public func removeDirectoryMetadata(forDirectoryPrefix dirPrefix: String) {
        service.removeDirectoryMetadata(forDirectoryPrefix: dirPrefix)
    }
    
    public func getPendingSyncFiles() -> [FileMetadata] {
        return service.getPendingSyncFiles()
    }
    
    // MARK: - 同步队列管理
    
    public func addToSyncQueue(_ operation: SyncOperation) {
        service.addToSyncQueue(operation)
    }

    public func enqueuePersistent(_ operation: SyncOperation, startProcessing: Bool = true) throws {
        try service.enqueuePersistent(operation, startProcessing: startProcessing)
    }

    public func retryFailedOperations() {
        service.queue.retryFailedOperations()
        service.processSyncQueue()
    }

    public var queue: OfflineSyncQueue { service.queue }
    
    public func removeItem(id: String) {
        service.queue.removeItem(id: id)
    }

    public func getQueuedOperations() -> [SyncQueueItem] { service.queue.getAllItems() }
    
    public func updatePendingOperation(oldFileId: String, newFileId: String, newRemotePath: String, newName: String, newParentId: String, sourceRemotePath: String? = nil) {
        service.updatePendingOperation(oldFileId: oldFileId, newFileId: newFileId, newRemotePath: newRemotePath, newName: newName, newParentId: newParentId, sourceRemotePath: sourceRemotePath)
    }
    
    public func hasPendingUpload(fileId: String) -> Bool {
        return service.hasPendingUpload(fileId: fileId)
    }

    public func removePendingUploads(for fileId: String) {
        service.removePendingUploads(for: fileId)
    }

    public func hasPendingOperation(fileId: String) -> Bool {
        return service.hasPendingOperation(fileId: fileId)
    }
    
    public func processSyncQueue() {
        service.processSyncQueue()
    }
    
    public func getSyncQueueCount() -> Int {
        return service.getSyncQueueCount()
    }
    
    // MARK: - 同步状态检测与目录同步
    
    public func detectSyncStatus(fileId: String, localPath: String?, remotePath: String?) async -> SyncStatus {
        return await service.detectSyncStatus(fileId: fileId, localPath: localPath, remotePath: remotePath)
    }
    
    public func syncDirectory(directoryId: String, localPath: String, remotePath: String) async throws -> [FileMetadata] {
        return try await service.syncDirectory(directoryId: directoryId, localPath: localPath, remotePath: remotePath)
    }
}
