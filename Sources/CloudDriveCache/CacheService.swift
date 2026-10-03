//
//  CacheService.swift
//  CloudDriveCache
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  缓存统一门面服务 (Cache Facade)
//

import Foundation
import CloudDriveContracts
import CloudDriveSync
import Darwin
import CryptoKit

/// 统一缓存服务类，组合物理存储、元数据、策略引擎、对账与通知
public final class CacheService: @unchecked Sendable {
    public static let shared = CacheService()
    
    public let storage: CacheDiskStorageProtocol
    public let metadataStore: CacheMetadataStoreProtocol
    public let policyEngine: CachePolicyEngineProtocol
    public let reconciler: CacheReconciler
    public let notifier: CacheNotificationService
    public let vaultId: String?
    let accessLock = NSLock()
    var activeAccesses: [String: Int] = [:]
    var accessDescriptors: [String: Int32] = [:]
    let injectedSyncManager: SyncManager?
    var configuredMaximumSize: Int64?
    var syncManager: SyncManager { injectedSyncManager ?? vaultId.map { SyncManager.forVault($0) } ?? .shared }

    static var sharedUserDefaults: UserDefaults {
        return UserDefaults(suiteName: "group.net.aabg.CloudDrive") ?? UserDefaults.standard
    }
    
    /// 用户可配置的最大缓存上限（默认 10GB）
    public var maxCacheSize: Int64 {
        get {
            if let configuredMaximumSize { return configuredMaximumSize }
            let defaults = Self.sharedUserDefaults
            let userVal = defaults.object(forKey: "clouddrive_max_cache_size") as? Int64
            return (userVal != nil && userVal! > 0) ? userVal! : (10 * 1024 * 1024 * 1024)
        }
        set {
            if configuredMaximumSize != nil { configuredMaximumSize = newValue; try? cleanupIfNeeded(); return }
            let defaults = Self.sharedUserDefaults
            defaults.set(newValue, forKey: "clouddrive_max_cache_size")
            try? cleanupIfNeeded()
        }
    }
    
    public init(
        storage: CacheDiskStorageProtocol = CacheDiskStorage(),
        metadataStore: CacheMetadataStoreProtocol = CacheMetadataStore(),
        policyEngine: CachePolicyEngineProtocol = CachePolicyEngine(),
        notifier: CacheNotificationService = CacheNotificationService.shared,
        vaultId: String? = nil,
        syncManager: SyncManager? = nil,
        maximumCacheSize: Int64? = nil
    ) {
        self.storage = storage
        self.metadataStore = metadataStore
        self.policyEngine = policyEngine
        self.notifier = notifier
        self.vaultId = vaultId
        self.injectedSyncManager = syncManager
        self.configuredMaximumSize = maximumCacheSize
        self.reconciler = CacheReconciler(storage: storage, metadataStore: metadataStore)
        
        // 启动时自动执行对账
        self.reconciler.reconcile()
    }

}
