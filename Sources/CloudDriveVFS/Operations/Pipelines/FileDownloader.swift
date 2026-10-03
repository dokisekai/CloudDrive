//
//  FileDownloader.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  文件下载操作流水线
//

import Foundation

/// 文件下载流水线执行器
public final class FileDownloader: @unchecked Sendable {
    private let context: FileOperationContext
    private let fileManager = FileManager.default
    
    public init(context: FileOperationContext) {
        self.context = context
    }
    
    /// 执行下载
    public func download(
        remotePath: String,
        fileId: String,
        destinationURL: URL? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        guard let storageClient = context.storageClient else {
            throw SyncError.storageNotConfigured
        }
        
        let targetURL = destinationURL ?? context.cacheService.localPath(for: fileId)
        let fileName = targetURL.lastPathComponent
        
        // 检查本地缓存是否已命中且有效
        if context.cacheService.isCached(fileId: fileId), fileManager.fileExists(atPath: targetURL.path) {
            Logger.shared.info(.cache, "Download cache hit for: \(fileId)")
            return targetURL
        }
        
        let opId = context.tracker.addOperation(
            type: .download,
            fileName: fileName,
            filePath: targetURL.path
        )
        
        context.tracker.updatePhase(id: opId, phase: .transferring(progress: 0.0, transferredBytes: 0, totalBytes: 0))
        
        let parentDir = targetURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        
        do {
            try await storageClient.downloadFile(path: remotePath, to: targetURL) { progress in
                self.context.tracker.updateProgress(id: opId, progress: progress)
                onProgress?(progress)
            }
            
            // 提交至缓存管理
            context.tracker.updatePhase(id: opId, phase: .committingCache)
            try? self.context.cacheService.cacheFile(fileId: fileId, from: targetURL, policy: .automatic)
            
            // 更新元数据
            context.tracker.updatePhase(id: opId, phase: .updatingDatabase)
            if var meta = self.context.syncService.getMetadata(fileId: fileId) {
                meta.syncStatus = .synced
                meta.localPath = targetURL.path
                meta.downloadProgress = 1.0
                meta.lastSyncTime = Date()
                self.context.syncService.updateMetadata(meta)
            }
            
            context.tracker.updatePhase(id: opId, phase: .completed(duration: 0))
            return targetURL
        } catch {
            context.tracker.updatePhase(id: opId, phase: .failed(error: error.localizedDescription, retryCount: 0))
            throw error
        }
    }
}
