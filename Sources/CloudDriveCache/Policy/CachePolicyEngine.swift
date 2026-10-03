//
//  CachePolicyEngine.swift
//  CloudDriveCache
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  缓存淘汰评分与策略计算引擎
//

import Foundation
import CloudDriveContracts

/// 纯算法缓存淘汰策略引擎
public final class CachePolicyEngine: CachePolicyEngineProtocol, Sendable {
    public init() {}
    
    public func selectCandidatesForEviction(
        from store: [String: CacheMetadata],
        currentTotalSize: Int64,
        maxAllowedSize: Int64,
        targetSize: Int64
    ) -> [CacheMetadata] {
        guard currentTotalSize > maxAllowedSize else { return [] }
        
        // 1. 过滤掉所有被固定的文件 (.pinned)，绝对不参与淘汰
        // 2. 优先清理临时文件 (.temporary)，然后是自动管理文件 (.automatic)
        // 3. 按照最后访问时间升序排列 (最久未被访问的排在最前)
        let candidates = store.values
            .filter { $0.policy != .pinned }
            .sorted { (lhs, rhs) -> Bool in
                if lhs.policy == .temporary && rhs.policy != .temporary {
                    return true
                }
                if lhs.policy != .temporary && rhs.policy == .temporary {
                    return false
                }
                return lhs.lastAccessedAt < rhs.lastAccessedAt
            }
        
        var selected: [CacheMetadata] = []
        var runningSize = currentTotalSize
        
        for item in candidates {
            if runningSize <= targetSize {
                break
            }
            selected.append(item)
            runningSize -= item.size
        }
        
        return selected
    }
}
