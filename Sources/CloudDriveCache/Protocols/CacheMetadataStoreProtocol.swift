//
//  CacheMetadataStoreProtocol.swift
//  CloudDriveCache
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  缓存元数据仓储协议
//

import Foundation
import CloudDriveContracts

/// 缓存元数据仓储协议
public protocol CacheMetadataStoreProtocol: AnyObject, Sendable {
    func get(for fileId: String) -> CacheMetadata?
    func set(_ metadata: CacheMetadata)
    func remove(for fileId: String) -> CacheMetadata?
    func removePrefix(_ prefix: String) -> [String]
    func updateLastAccessed(for fileId: String, date: Date)
    func setPolicy(for fileId: String, policy: CachePolicy)
    func getAllMetadata() -> [String: CacheMetadata]
    func getAllKeys() -> [String]
    func getAllPinnedFileIds() -> [String]
    func getStatistics() -> (totalSize: Int64, fileCount: Int)
    func clearAll()
    func save(immediate: Bool)
    func reloadIfNeeded()
    func getEvictionCandidates(limit: Int) -> [CacheMetadata]
}

public extension CacheMetadataStoreProtocol {
    func getEvictionCandidates(limit: Int = 100) -> [CacheMetadata] {
        getAllMetadata().values
            .filter { $0.policy != .pinned }
            .sorted { (lhs, rhs) -> Bool in
                if lhs.policy == .temporary && rhs.policy != .temporary { return true }
                if lhs.policy != .temporary && rhs.policy == .temporary { return false }
                return lhs.lastAccessedAt < rhs.lastAccessedAt
            }
            .prefix(limit)
            .map { $0 }
    }
}
