//
//  FileMover.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  文件与目录移动/重命名操作流水线
//

import Foundation

/// 文件与目录移动流水线执行器
public final class FileMover: @unchecked Sendable {
    private let context: FileOperationContext
    
    public init(context: FileOperationContext) {
        self.context = context
    }
    
    /// 执行移动或重命名
    public func move(
        sourceRemotePath: String,
        targetRemotePath: String,
        sourceId: String,
        targetId: String,
        newParentId: String,
        newName: String,
        isDirectory: Bool = false
    ) async throws {
        guard let storageClient = context.storageClient else {
            throw SyncError.storageNotConfigured
        }
        
        // 循环嵌套校验：禁止将父目录移动到其自身子目录下
        if isDirectory {
            let cleanSource = sourceRemotePath.hasSuffix("/") ? sourceRemotePath : "\(sourceRemotePath)/"
            if targetRemotePath.hasPrefix(cleanSource) {
                throw StorageError.invalidOperation
            }
        }
        
        let opId = context.tracker.addOperation(
            type: .move,
            fileName: newName,
            filePath: targetRemotePath
        )
        
        context.tracker.updatePhase(id: opId, phase: .transferring(progress: 0.0, transferredBytes: 0, totalBytes: 0))
        
        do {
            // 1. 远端存储移动
            try await storageClient.move(from: sourceRemotePath, to: targetRemotePath)
            
            // 2. 本地缓存迁移
            context.tracker.updatePhase(id: opId, phase: .committingCache)
            if !isDirectory {
                try? context.cacheService.moveCache(from: sourceId, to: targetId)
            }
            
            // 3. 元数据与数据库级联迁移
            context.tracker.updatePhase(id: opId, phase: .updatingDatabase)
            if isDirectory {
                context.syncService.moveDirectoryMetadata(
                    from: sourceId,
                    to: targetId,
                    newParentId: newParentId,
                    newName: newName,
                    newRemotePath: targetRemotePath
                )
            } else {
                context.syncService.moveMetadata(
                    from: sourceId,
                    to: targetId,
                    newParentId: newParentId,
                    newName: newName,
                    newRemotePath: targetRemotePath,
                    fallbackStatus: .synced
                )
            }
            
            context.tracker.updatePhase(id: opId, phase: .completed(duration: 0))
        } catch {
            context.tracker.updatePhase(id: opId, phase: .failed(error: error.localizedDescription, retryCount: 0))
            throw error
        }
    }
}
