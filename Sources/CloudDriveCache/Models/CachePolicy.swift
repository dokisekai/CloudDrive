//
//  CachePolicy.swift
//  CloudDriveCache
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  缓存策略枚举定义
//

import Foundation
import CloudDriveContracts

/// 缓存策略
public enum CachePolicy: String, Codable, Sendable, CaseIterable {
    case automatic      // 自动管理 (按 LRU 算法择优清理)
    case pinned         // 固定锁定 (永不自动清理，常驻本地)
    case temporary      // 临时缓存 (优先清理)
}
