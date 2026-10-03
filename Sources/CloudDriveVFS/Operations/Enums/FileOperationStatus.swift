//
//  FileOperationStatus.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  文件操作状态枚举
//

import Foundation

/// 文件操作状态枚举
public enum FileOperationStatus: String, Codable, Sendable {
    case pending = "等待中"
    case inProgress = "进行中"
    case completed = "已完成"
    case failed = "失败"
    case cancelled = "已取消"
    
    public var icon: String {
        switch self {
        case .pending:
            return "clock"
        case .inProgress:
            return "arrow.triangle.2.circlepath"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .cancelled:
            return "minus.circle"
        }
    }
    
    public var color: String {
        switch self {
        case .pending:
            return "orange"
        case .inProgress:
            return "blue"
        case .completed:
            return "green"
        case .failed:
            return "red"
        case .cancelled:
            return "gray"
        }
    }
}
