//
//  FileOperationType.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  文件操作类型枚举
//

import Foundation

/// 文件操作类型枚举
public enum FileOperationType: String, Codable, Sendable {
    case create = "创建"
    case delete = "删除"
    case move = "移动"
    case copy = "复制"
    case upload = "上传"
    case download = "下载"
    case modify = "修改"
    case rename = "重命名"
    
    public var icon: String {
        switch self {
        case .create:
            return "doc.badge.plus"
        case .delete:
            return "trash"
        case .move:
            return "arrow.right.arrow.left"
        case .copy:
            return "doc.on.doc"
        case .upload:
            return "arrow.up.circle"
        case .download:
            return "arrow.down.circle"
        case .modify:
            return "pencil"
        case .rename:
            return "pencil.circle"
        }
    }
}
