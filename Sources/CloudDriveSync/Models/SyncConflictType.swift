import Foundation

/// 冲突类型枚举
public enum SyncConflictType: Sendable, Equatable {
    case none
    case bothModified(localMod: Date, remoteMod: Date)
    case deletedOnRemote
    case deletedOnLocal
}

