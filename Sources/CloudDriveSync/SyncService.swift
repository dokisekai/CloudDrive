//
//  SyncService.swift
//  CloudDriveSync
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  同步子系统统一门面服务
//

import Foundation
import CloudDriveContracts
import CloudDriveSupport

/// 统一同步服务类
public final class SyncService: @unchecked Sendable {
    public static let shared = SyncService()
    
    let fileManager = FileManager.default
    public let metadataStore: SyncMetadataStore
    public let queue: OfflineSyncQueue
    public let networkMonitor: NetworkMonitorServiceProtocol
    public let conflictResolver: SyncConflictResolver
    
    let processingLock = NSLock()
    var isProcessingQueue = false
    var hasPendingQueueCheck = false
    
    public let vaultId: String?
    let contextLock = NSLock()
    var storageClient: StorageClient?
    weak var configuredVFS: (any SyncVaultAccess)?
    var scheduledRetry: Task<Void, Never>?
    let automaticallyProcessesQueue: Bool
    let notifiesFileProvider: Bool

    public var activeVFS: (any SyncVaultAccess)? {
        get { contextLock.withLock { configuredVFS } }
        set {
            guard newValue == nil || vaultId == nil || newValue?.vaultId == vaultId else {
                Logger.shared.error(.sync, "Refusing VFS from a different vault")
                return
            }
            contextLock.withLock { configuredVFS = newValue }
        }
    }
    
    public init(
        vaultId: String? = nil,
        metadataStore: SyncMetadataStore? = nil,
        queue: OfflineSyncQueue? = nil,
        networkMonitor: NetworkMonitorServiceProtocol = NetworkMonitorService.shared,
        conflictResolver: SyncConflictResolver = SyncConflictResolver(),
        automaticallyProcessesQueue: Bool = true,
        notifiesFileProvider: Bool = true
    ) {
        self.vaultId = vaultId
        self.metadataStore = metadataStore ?? SyncMetadataStore(metadataURL: SyncStoragePaths.directory(for: vaultId).appendingPathComponent("sync_metadata.json"), vaultId: vaultId)
        self.queue = queue ?? OfflineSyncQueue(queueURL: SyncStoragePaths.directory(for: vaultId).appendingPathComponent("sync_queue.json"))
        self.automaticallyProcessesQueue = automaticallyProcessesQueue
        self.notifiesFileProvider = notifiesFileProvider
        self.networkMonitor = networkMonitor
        self.conflictResolver = conflictResolver
        
        // 注册网络恢复回调
        self.networkMonitor.onStatusChanged { [weak self] status in
            if status == .online {
                self?.queue.retryTransientOperations()
                self?.processSyncQueue()
            }
        }
        
        Logger.shared.info(.sync, "SyncService initialized")
    }
    
    public func configure(storageClient: StorageClient, vfs: (any SyncVaultAccess)? = nil) {
        guard vfs == nil || vaultId == nil || vfs?.vaultId == vaultId else {
            Logger.shared.error(.sync, "Refusing storage configuration from a different vault")
            return
        }
        contextLock.withLock {
            self.storageClient = storageClient
            if let vfs { self.configuredVFS = vfs }
        }
        processSyncQueue()
    }
    
    public func getStorageClient() -> StorageClient? {
        return contextLock.withLock { storageClient }
    }
    
    public func getNetworkStatus() -> NetworkStatus {
        networkMonitor.currentStatus
    }
    
}
