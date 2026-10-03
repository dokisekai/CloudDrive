//
//  SyncError.swift
//  CloudDriveSync
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  同步子系统错误定义
//

import Foundation
import CloudDriveContracts

/// 同步错误枚举
public enum SyncError: Error, LocalizedError {
    case storageNotConfigured
    case networkUnavailable
    case conflictDetected
    case operationFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .storageNotConfigured:
            return "存储未配置"
        case .networkUnavailable:
            return "网络不可用"
        case .conflictDetected:
            return "检测到冲突"
        case .operationFailed(let detail):
            return "操作失败: \(detail)"
        }
    }
}
