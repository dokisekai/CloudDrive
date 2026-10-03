//
//  CacheEvictionReason.swift
//  CloudDriveCache
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  缓存驱逐原因枚举
//

import Foundation
import CloudDriveContracts

/// 缓存淘汰原因枚举
public enum CacheEvictionReason: String, Codable, Sendable {
    case quotaExceeded        = "quota_exceeded"        // 超过用户设置的上限 (如 10GB)
    case manualUserEviction   = "manual_user_eviction"  // 访达右键或用户设置手动清理
    case remoteItemDeleted    = "remote_item_deleted"   // 远端文件已被删除，清理本地副本
    case localTemporaryStale  = "temporary_stale"       // 标记为 .temporary 的文件超时
    case contentUpdatedStale  = "content_updated_stale" // 远端有新版本，旧版本缓存失效
    case reconciliationOrphan = "reconciliation_orphan" // 对账发现的未记账孤儿文件
}
