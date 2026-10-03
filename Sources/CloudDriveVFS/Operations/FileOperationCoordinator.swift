//
//  FileOperationCoordinator.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  文件操作总协调器（统一门面）
//

import Foundation

/// 文件操作总协调器
public final class FileOperationCoordinator: @unchecked Sendable {
    public static let shared = FileOperationCoordinator()
    
    public var context: FileOperationContext
    public let tracker: FileOperationTracker
    
    public init(
        context: FileOperationContext = FileOperationContext(),
        tracker: FileOperationTracker = FileOperationTracker.shared
    ) {
        self.context = context
        self.tracker = tracker
    }
    
    /// 更新环境依赖
    public func updateContext(
        storageClient: StorageClient? = nil,
        database: VFSDatabase? = nil,
        vaultId: String? = nil,
        isEncrypted: Bool = false
    ) {
        if let sc = storageClient { self.context.storageClient = sc }
        if let db = database { self.context.database = db }
        if let vId = vaultId { self.context.vaultId = vId }
        self.context.isEncrypted = isEncrypted
    }
    
    /// 上传文件
    public func uploadFile(
        localURL: URL,
        remotePath: String,
        fileId: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let uploader = FileUploader(context: context)
        try await uploader.upload(localURL: localURL, remotePath: remotePath, fileId: fileId, onProgress: onProgress)
    }
    
    /// 下载文件
    public func downloadFile(
        remotePath: String,
        fileId: String,
        destinationURL: URL? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let downloader = FileDownloader(context: context)
        return try await downloader.download(remotePath: remotePath, fileId: fileId, destinationURL: destinationURL, onProgress: onProgress)
    }
    
    /// 删除文件或文件夹
    public func delete(
        remotePath: String,
        fileId: String,
        isDirectory: Bool = false
    ) async throws {
        let deleter = FileDeleter(context: context)
        try await deleter.delete(remotePath: remotePath, fileId: fileId, isDirectory: isDirectory)
    }
    
    /// 移动或重命名
    public func move(
        sourceRemotePath: String,
        targetRemotePath: String,
        sourceId: String,
        targetId: String,
        newParentId: String,
        newName: String,
        isDirectory: Bool = false
    ) async throws {
        let mover = FileMover(context: context)
        try await mover.move(
            sourceRemotePath: sourceRemotePath,
            targetRemotePath: targetRemotePath,
            sourceId: sourceId,
            targetId: targetId,
            newParentId: newParentId,
            newName: newName,
            isDirectory: isDirectory
        )
    }
    
    /// 复制文件或文件夹
    public func copy(
        sourceRemotePath: String,
        targetRemotePath: String,
        sourceId: String,
        targetId: String,
        newParentId: String,
        newName: String,
        isDirectory: Bool = false
    ) async throws {
        let copier = FileCopier(context: context)
        try await copier.copy(
            sourceRemotePath: sourceRemotePath,
            targetRemotePath: targetRemotePath,
            sourceId: sourceId,
            targetId: targetId,
            newParentId: newParentId,
            newName: newName,
            isDirectory: isDirectory
        )
    }
}
