//
//  FileDeleter.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  文件与目录删除操作流水线
//

import Foundation

/// 文件与目录删除流水线执行器
public final class FileDeleter: @unchecked Sendable {
    private let context: FileOperationContext
    
    public init(context: FileOperationContext) {
        self.context = context
    }
    
    /// 执行删除
    public func delete(
        remotePath: String,
        fileId: String,
        isDirectory: Bool = false
    ) async throws {
        guard let storageClient = context.storageClient else {
            throw SyncError.storageNotConfigured
        }
        
        let fileName = (remotePath as NSString).lastPathComponent
        let opId = context.tracker.addOperation(
            type: .delete,
            fileName: fileName,
            filePath: remotePath
        )
        
        context.tracker.updatePhase(id: opId, phase: .transferring(progress: 0.0, transferredBytes: 0, totalBytes: 0))
        
        do {
            // 1. 远端存储删除
            try await storageClient.delete(path: remotePath)
            
            // 2. 本地缓存清理
            context.tracker.updatePhase(id: opId, phase: .committingCache)
            if isDirectory {
                context.cacheService.removeDirectoryCache(forDirectoryPrefix: fileId)
                context.syncService.removeDirectoryMetadata(forDirectoryPrefix: fileId)
            } else {
                try? context.cacheService.removeCachedFile(fileId: fileId)
                context.syncService.removeMetadata(fileId: fileId)
            }
            
            // 3. 数据库记录清理
            context.tracker.updatePhase(id: opId, phase: .updatingDatabase)
            if let db = context.database {
                if isDirectory {
                    try? db.deleteDirectory(id: fileId)
                } else {
                    try? db.deleteFile(id: fileId)
                }
            }
            
            context.tracker.updatePhase(id: opId, phase: .completed(duration: 0))
        } catch {
            context.tracker.updatePhase(id: opId, phase: .failed(error: error.localizedDescription, retryCount: 0))
            throw error
        }
    }
}
