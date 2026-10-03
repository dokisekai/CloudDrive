//
//  CacheMetadata.swift
//  CloudDriveCache
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  缓存元数据模型
//

import Foundation
import CloudDriveContracts

/// 缓存元数据实体
public struct CacheMetadata: Codable, Sendable, Equatable {
    public let fileId: String
    public let size: Int64
    public let downloadedAt: Date
    public var lastAccessedAt: Date
    public var policy: CachePolicy
    
    public init(
        fileId: String,
        size: Int64,
        downloadedAt: Date,
        lastAccessedAt: Date,
        policy: CachePolicy
    ) {
        self.fileId = fileId
        self.size = size
        self.downloadedAt = downloadedAt
        self.lastAccessedAt = lastAccessedAt
        self.policy = policy
    }
}
