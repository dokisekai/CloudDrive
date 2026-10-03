//
//  CachePolicyEngineProtocol.swift
//  CloudDriveCache
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  缓存淘汰策略引擎协议
//

import Foundation
import CloudDriveContracts

/// 缓存淘汰策略引擎协议
public protocol CachePolicyEngineProtocol: Sendable {
    /// 计算超标需要淘汰的文件元数据列表
    func selectCandidatesForEviction(
        from store: [String: CacheMetadata],
        currentTotalSize: Int64,
        maxAllowedSize: Int64,
        targetSize: Int64
    ) -> [CacheMetadata]
}
