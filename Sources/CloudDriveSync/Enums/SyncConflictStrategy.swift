//
//  SyncConflictStrategy.swift
//  CloudDriveSync
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  同步冲突处理策略枚举
//

import Foundation
import CloudDriveContracts

public enum SyncConflictStrategy: String, Codable, CaseIterable, Sendable {
    case localWins           = "local_wins"            // 以本地修改为准，强制覆盖云端
    case remoteWins          = "remote_wins"           // 以云端最新为准，丢弃本地修改
    case forkBothWithSuffix  = "fork_both_with_suffix" // 分叉：保留云端，本地文件重命名为 副本 (Conflict) 并上传
    case promptUser          = "prompt_user"           // 暂停并通知访达展示黄色警告标，等待用户选择
}
