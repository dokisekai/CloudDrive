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
import Darwin
import CryptoKit

extension CacheService {
    public func updateLastAccessed(fileId: String) {
        metadataStore.updateLastAccessed(for: fileId, date: Date())
        metadataStore.save(immediate: false)
    }

    public func getCacheMetadata(fileId: String) -> CacheMetadata? {
        metadataStore.get(for: fileId)
    }

    public func getAllCachedFileIds() -> [String] {
        metadataStore.getAllKeys()
    }

    public func getCacheStatistics() -> (totalSize: Int64, fileCount: Int) {
        metadataStore.getStatistics()
    }
}
