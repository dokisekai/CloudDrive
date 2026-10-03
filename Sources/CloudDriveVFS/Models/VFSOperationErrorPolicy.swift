//
//  VFSOperationErrorPolicy.swift
//  CloudDriveVFS
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  VFS 操作错误与离线重试判定策略
//

import Foundation
import CloudDriveContracts

public enum VFSOperationErrorPolicy {
    public static func permitsOfflineRetry(_ error: Error) -> Bool {
        if let error = error as? URLError { return error.code != .cancelled }
        if let error = error as? StorageError {
            switch error {
            case .networkError: return true
            case .serverError(let code, _): return code == 429 || code >= 500
            default: return false
            }
        }
        if case WebDAVError.serverError(let code) = error { return code == 429 || code >= 500 }
        return false
    }
}
