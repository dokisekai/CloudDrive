//
//  SyncStatus.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  文件同步状态管理
//

import Foundation

// MARK: - 同步状态枚举

/// 文件同步状态
public enum SyncStatus: String, Codable {
    case localOnly          // 仅在本地（未上传）
    case cloudOnly          // 仅在云端（未下载）
    case synced             // 已同步（本地和云端一致）
    case uploading          // 上传中
    case downloading        // 下载中
    case conflict           // 冲突（本地和云端都有修改）
    case pendingUpload      // 等待上传（离线时创建）
    case pendingDelete      // 等待删除（离线时删除）
    case error              // 同步错误
    case partialUpload      // 大文件部分上传完成
    case partialDownload    // 大文件部分下载完成
    case verifying          // 正在校验文件完整性
    case locked             // 文件被其他进程锁定
    case pendingMove        // 离线时移动/重命名，等待同步
    case temporary          // 临时文件，等待确认或清理
    
    /// 是否可以离线访问
    public var isAvailableOffline: Bool {
        switch self {
        case .localOnly, .synced, .uploading, .pendingUpload, .conflict, .partialUpload, .verifying, .locked, .pendingMove, .temporary:
            return true
        case .cloudOnly, .downloading, .pendingDelete, .error, .partialDownload:
            return false
        }
    }
    
    /// 是否需要同步
    public var needsSync: Bool {
        switch self {
        case .pendingUpload, .pendingDelete, .conflict, .pendingMove, .partialUpload, .partialDownload:
            return true
        default:
            return false
        }
    }
    
    /// 同步优先级
    public var syncPriority: Int {
        switch self {
        case .conflict, .pendingDelete, .error:
            return 5  // 高优先级
        case .pendingUpload, .pendingMove, .partialUpload:
            return 3  // 中优先级
        case .cloudOnly, .partialDownload:
            return 2  // 低优先级
        case .temporary:
            return 1  // 后台优先级
        default:
            return 0  // 无需同步
        }
    }
    
    /// 状态图标
    public var icon: String {
        switch self {
        case .localOnly:
            return "arrow.up.circle"
        case .cloudOnly:
            return "icloud.and.arrow.down"
        case .synced:
            return "checkmark.icloud"
        case .uploading:
            return "arrow.up.circle.fill"
        case .downloading:
            return "arrow.down.circle.fill"
        case .conflict:
            return "exclamationmark.triangle"
        case .pendingUpload:
            return "clock.arrow.circlepath"
        case .pendingDelete:
            return "trash.circle"
        case .error:
            return "xmark.icloud"
        case .partialUpload:
            return "arrow.up.circle.badge.clock"
        case .partialDownload:
            return "arrow.down.circle.badge.clock"
        case .verifying:
            return "checkmark.seal"
        case .locked:
            return "lock.circle"
        case .pendingMove:
            return "folder.badge.gearshape"
        case .temporary:
            return "clock.badge.questionmark"
        }
    }
    
    /// 状态描述
    public var description: String {
        switch self {
        case .localOnly:
            return "仅本地"
        case .cloudOnly:
            return "仅云端"
        case .synced:
            return "已同步"
        case .uploading:
            return "上传中"
        case .downloading:
            return "下载中"
        case .conflict:
            return "冲突"
        case .pendingUpload:
            return "等待上传"
        case .pendingDelete:
            return "等待删除"
        case .error:
            return "同步错误"
        case .partialUpload:
            return "部分上传"
        case .partialDownload:
            return "部分下载"
        case .verifying:
            return "校验中"
        case .locked:
            return "锁定中"
        case .pendingMove:
            return "等待移动"
        case .temporary:
            return "临时状态"
        }
    }
}

// MARK: - 网络状态

/// 网络连接状态
public enum NetworkStatus: String, Codable {
    case unknown = "unknown"
    case offline = "offline"
    case online = "online"
    case limited = "limited"  // 受限连接（如移动数据）
}

// MARK: - 同步操作

/// 同步操作类型
public enum SyncOperation: Codable {
    case upload(fileId: String, localPath: String, remotePath: String)
    case download(fileId: String, remotePath: String, localPath: String)
    case delete(fileId: String, remotePath: String)
    case createDirectory(directoryId: String, name: String, parentId: String, remotePath: String)
    
    /// 获取操作的文件ID
    public var fileId: String {
        switch self {
        case .upload(let fileId, _, _):
            return fileId
        case .download(let fileId, _, _):
            return fileId
        case .delete(let fileId, _):
            return fileId
        case .createDirectory(let directoryId, _, _, _):
            return directoryId
        }
    }
    
    /// 操作类型描述
    public var description: String {
        switch self {
        case .upload:
            return "上传"
        case .download:
            return "下载"
        case .delete:
            return "删除"
        case .createDirectory:
            return "创建目录"
        }
    }
}

// MARK: - 同步队列项

/// 同步队列中的项目
public struct SyncQueueItem: Codable {
    public let id: String
    public let operation: SyncOperation
    public let createdAt: Date
    public var retryCount: Int
    public var lastError: String?
    
    public init(operation: SyncOperation) {
        self.id = UUID().uuidString
        self.operation = operation
        self.createdAt = Date()
        self.retryCount = 0
        self.lastError = nil
    }
}

// MARK: - 文件元数据

/// 文件元数据（用于同步状态跟踪）
public struct FileMetadata: Codable {
    public let fileId: String
    public let name: String
    public let parentId: String
    public let isDirectory: Bool
    public var syncStatus: SyncStatus
    public var localPath: String?
    public var remotePath: String?
    public var size: Int64
    public var localModifiedAt: Date?
    public var remoteModifiedAt: Date?
    public var etag: String?
    public var downloadProgress: Double  // 新增下载进度字段 (0.0 到 1.0)
    
    public init(
        fileId: String,
        name: String,
        parentId: String,
        isDirectory: Bool,
        syncStatus: SyncStatus,
        localPath: String? = nil,
        remotePath: String? = nil,
        size: Int64 = 0,
        localModifiedAt: Date? = nil,
        remoteModifiedAt: Date? = nil,
        etag: String? = nil,
        downloadProgress: Double = 0.0  // 默认下载进度为0
    ) {
        self.fileId = fileId
        self.name = name
        self.parentId = parentId
        self.isDirectory = isDirectory
        self.syncStatus = syncStatus
        self.localPath = localPath
        self.remotePath = remotePath
        self.size = size
        self.localModifiedAt = localModifiedAt
        self.remoteModifiedAt = remoteModifiedAt
        self.etag = etag
        self.downloadProgress = downloadProgress
    }
    
    /// 检查是否有冲突
    public func hasConflict() -> Bool {
        guard let localMod = localModifiedAt,
              let remoteMod = remoteModifiedAt else {
            return false
        }
        
        // 如果本地和远程都有修改，且时间不一致，则认为有冲突
        return abs(localMod.timeIntervalSince(remoteMod)) > 1.0 // 允许1秒误差
    }
}
