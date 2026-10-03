//
//  FileOperationPhase.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  文件操作全生命周期阶段枚举
//

import Foundation

/// 文件操作全生命周期阶段枚举
public enum FileOperationPhase: Sendable, Equatable {
    case queued                                                                 // 1. 排队中
    case validating(rule: String)                                               // 2. 校验过滤规则 (.clouddriveignore)
    case preparingDirectory(path: String)                                       // 3. 远端父目录层级确认
    case encrypting(progress: Double)                                           // 4. 加密中 (Format 7/8 分块认证加密)
    case decrypting(progress: Double)                                           // 5. 解密中
    case transferring(progress: Double, transferredBytes: Int64, totalBytes: Int64) // 6. 传输中
    case committingCache                                                        // 7. 本地物理缓存落盘
    case updatingDatabase                                                       // 8. SQLite 元数据持久化
    case notifyingFileProvider                                                  // 9. 触发系统 Enumerator 信号
    case completed(duration: TimeInterval)                                      // 10. 成功结束
    case failed(error: String, retryCount: Int)                                 // 11. 失败
    case cancelled                                                              // 12. 取消
    
    public var description: String {
        switch self {
        case .queued:
            return "排队中"
        case .validating(let rule):
            return "校验规则: \(rule)"
        case .preparingDirectory(let path):
            return "准备目录: \(path)"
        case .encrypting(let progress):
            return "加密中 (\(Int(progress * 100))%)"
        case .decrypting(let progress):
            return "解密中 (\(Int(progress * 100))%)"
        case .transferring(let progress, _, _):
            return "传输中 (\(Int(progress * 100))%)"
        case .committingCache:
            return "写入本地缓存"
        case .updatingDatabase:
            return "更新本地数据库"
        case .notifyingFileProvider:
            return "通知访达刷新"
        case .completed:
            return "已完成"
        case .failed(let error, _):
            return "失败: \(error)"
        case .cancelled:
            return "已取消"
        }
    }
}
