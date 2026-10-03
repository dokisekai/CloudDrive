//
//  SyncService.swift
//  CloudDriveSync
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  同步子系统统一门面服务
//

import Foundation
import CloudDriveContracts

extension SyncService {
    // MARK: - 状态检测
    
    public func detectSyncStatus(fileId: String, localPath: String?, remotePath: String?) async -> SyncStatus {
        let hasLocal = localPath != nil && fileManager.fileExists(atPath: localPath!)
        let hasRemote = remotePath != nil
        
        let inQueue = queue.getAllItems().first { $0.operation.fileId == fileId }
        if let item = inQueue {
            switch item.operation {
            case .upload:
                return .pendingUpload
            case .delete, .deleteItem:
                return .pendingDelete
            case .encryptedUpload, .createDirectory, .encryptedCreateDirectory:
                return .pendingUpload
            case .move:
                return .pendingMove
            default:
                break
            }
        }
        
        if hasLocal && hasRemote {
            if let metadata = getMetadata(fileId: fileId), metadata.hasConflict() {
                return .conflict
            }
            return .synced
        } else if hasLocal && !hasRemote {
            return .localOnly
        } else if !hasLocal && hasRemote {
            return .cloudOnly
        } else {
            return .error
        }
    }
    

}
