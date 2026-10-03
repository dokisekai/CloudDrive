//
//  VFSNodeKind.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  虚拟文件系统节点类别枚举
//

import Foundation

/// VFS 节点类别枚举
public enum VFSNodeKind: Sendable, Codable, Equatable {
    case regularFile(size: Int64, contentType: String?)
    case directory(childCount: Int?)
    case symbolicLink(destination: String)
    case encryptedC9sFolder(realTargetDirId: String) // Cryptomator 超长文件名特殊目录
    case placeholder(isFault: Bool)                  // 离线/按需未拉取的占位虚拟节点
}
