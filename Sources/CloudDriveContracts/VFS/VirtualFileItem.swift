//
//  VirtualFileItem.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  虚拟文件项模型
//

import Foundation

/// 虚拟文件项
public struct VirtualFileItem: Sendable {
    public let id: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modifiedAt: Date
    public let parentId: String
    
    // 同步状态相关
    public var syncStatus: SyncStatus
    public var localPath: String?
    public var remotePath: String?
    public var etag: String?
    
    public init(
        id: String,
        name: String,
        isDirectory: Bool,
        size: Int64,
        modifiedAt: Date,
        parentId: String,
        syncStatus: SyncStatus = .synced,
        localPath: String? = nil,
        remotePath: String? = nil,
        etag: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
        self.parentId = parentId
        self.syncStatus = syncStatus
        self.localPath = localPath
        self.remotePath = remotePath
        self.etag = etag
    }
}

public extension SyncStatus {
    /// A directory refresh or cache read cannot confirm that these local changes reached storage.
    var protectsLocalChanges: Bool {
        switch self {
        case .pendingUpload, .uploading, .localOnly, .partialUpload, .pendingMove, .conflict, .error, .pendingDelete:
            return true
        default:
            return false
        }
    }
}

