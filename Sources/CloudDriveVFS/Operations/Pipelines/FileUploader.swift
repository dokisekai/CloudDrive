//
//  FileUploader.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  文件上传操作流水线
//

import Foundation

/// 文件上传流水线执行器
public final class FileUploader: @unchecked Sendable {
    private let context: FileOperationContext
    private let fileManager = FileManager.default
    
    public init(context: FileOperationContext) {
        self.context = context
    }
    
    /// 执行上传
    public func upload(
        localURL: URL,
        remotePath: String,
        fileId: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard let storageClient = context.storageClient else {
            throw SyncError.storageNotConfigured
        }
        
        let fileName = localURL.lastPathComponent
        let opId = context.tracker.addOperation(
            type: .upload,
            fileName: fileName,
            filePath: remotePath
        )
        
        context.tracker.updatePhase(id: opId, phase: .transferring(progress: 0.0, transferredBytes: 0, totalBytes: 0))
        
        do {
            try await storageClient.uploadFile(localURL: localURL, to: remotePath) { progress in
                self.context.tracker.updateProgress(id: opId, progress: progress)
                onProgress?(progress)
            }
            
            // 写入本地缓存
            context.tracker.updatePhase(id: opId, phase: .committingCache)
            try? self.context.cacheService.cacheFile(fileId: fileId, from: localURL, policy: .automatic)
            
            // 更新元数据
            context.tracker.updatePhase(id: opId, phase: .updatingDatabase)
            var meta = self.context.syncService.getMetadata(fileId: fileId) ?? FileMetadata(
                fileId: fileId,
                name: fileName,
                parentId: (remotePath as NSString).deletingLastPathComponent,
                isDirectory: false,
                syncStatus: .synced
            )
            meta.syncStatus = .synced
            meta.remotePath = remotePath
            meta.localPath = self.context.cacheService.localPath(for: fileId).path
            meta.remoteModifiedAt = Date()
            meta.lastSyncTime = Date()
            self.context.syncService.updateMetadata(meta)
            
            context.tracker.updatePhase(id: opId, phase: .completed(duration: 0))
        } catch {
            context.tracker.updatePhase(id: opId, phase: .failed(error: error.localizedDescription, retryCount: 0))
            throw error
        }
    }
}
