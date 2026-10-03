import CloudDriveContracts
import CloudDriveSupport
//
//  DatabaseTransactionMode.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  数据库事务模式枚举
//

import Foundation

public enum DatabaseTransactionMode: String, Sendable {
    case deferred = "DEFERRED"
    case immediate = "IMMEDIATE"
    case exclusive = "EXCLUSIVE"
}
