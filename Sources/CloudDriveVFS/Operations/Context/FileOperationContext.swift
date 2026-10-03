//
//  FileOperationContext.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  文件操作执行上下文（依赖注入容器）
//

import Foundation

/// 文件操作执行依赖上下文
public struct FileOperationContext: @unchecked Sendable {
    public var storageClient: StorageClient?
    public var cacheService: CacheService
    public var database: VFSDatabase?
    public var syncService: SyncService
    public var tracker: FileOperationTracker
    public var vaultId: String?
    public var isEncrypted: Bool
    
    public init(
        storageClient: StorageClient? = nil,
        cacheService: CacheService = CacheService.shared,
        database: VFSDatabase? = nil,
        syncService: SyncService = SyncService.shared,
        tracker: FileOperationTracker = FileOperationTracker.shared,
        vaultId: String? = nil,
        isEncrypted: Bool = false
    ) {
        self.storageClient = storageClient
        self.cacheService = cacheService
        self.database = database
        self.syncService = syncService
        self.tracker = tracker
        self.vaultId = vaultId
        self.isEncrypted = isEncrypted
    }
}
