//
//  FileCopier.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  文件与目录复制操作流水线
//

import Foundation

/// 文件与目录复制流水线执行器
public final class FileCopier: @unchecked Sendable {
    private let context: FileOperationContext
    
    public init(context: FileOperationContext) {
        self.context = context
    }
    
    /// 执行复制
    public func copy(
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
        
        let opId = context.tracker.addOperation(
            type: .copy,
            fileName: newName,
            filePath: targetRemotePath
        )
        
        context.tracker.updatePhase(id: opId, phase: .transferring(progress: 0.0, transferredBytes: 0, totalBytes: 0))
        
        do {
            // 远端存储复制
            try await storageClient.copy(from: sourceRemotePath, to: targetRemotePath)
            
            // 如果本地有缓存，复制缓存
            context.tracker.updatePhase(id: opId, phase: .committingCache)
            if !isDirectory, context.cacheService.isCached(fileId: sourceId) {
                let srcURL = context.cacheService.localPath(for: sourceId)
                try? context.cacheService.cacheFile(fileId: targetId, from: srcURL, policy: .automatic)
            }
            
            // 更新元数据
            context.tracker.updatePhase(id: opId, phase: .updatingDatabase)
            let meta = FileMetadata(
                fileId: targetId,
                name: newName,
                parentId: newParentId,
                isDirectory: isDirectory,
                syncStatus: .synced,
                remotePath: targetRemotePath,
                localModifiedAt: Date(),
                remoteModifiedAt: Date(),
                lastSyncTime: Date()
            )
            context.syncService.updateMetadata(meta)
            
            context.tracker.updatePhase(id: opId, phase: .completed(duration: 0))
        } catch {
            context.tracker.updatePhase(id: opId, phase: .failed(error: error.localizedDescription, retryCount: 0))
            throw error
        }
    }
}
