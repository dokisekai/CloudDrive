import Foundation

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
    public var downloadProgress: Double  // 下载进度字段 (0.0 到 1.0)
    public var lastSyncTime: Date?       // 最后成功同步时间
    
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
        downloadProgress: Double = 0.0,
        lastSyncTime: Date? = nil
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
        self.lastSyncTime = lastSyncTime
    }
    
    /// 检查是否有冲突（基于 lastSyncTime 判断双向修改）
    public func hasConflict() -> Bool {
        guard let localMod = localModifiedAt,
              let remoteMod = remoteModifiedAt,
              let syncTime = lastSyncTime else {
            return false
        }
        // 本地和远程都在上次同步后被修改过 → 冲突
        return localMod > syncTime && remoteMod > syncTime
    }
    
    /// 计算属性：是否有同步冲突
    public var hasSyncConflict: Bool {
        return hasConflict()
    }
}
