import Foundation

public enum SyncStatus: String, Codable, Sendable {
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
        case .pendingUpload, .pendingDelete, .conflict, .pendingMove, .partialUpload, .partialDownload, .error:
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
