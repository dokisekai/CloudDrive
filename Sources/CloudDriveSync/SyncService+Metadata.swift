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
import CloudDriveSupport

extension SyncService {
    // MARK: - 元数据转发
    
    public func updateMetadata(_ metadata: FileMetadata) {
        metadataStore.updateMetadata(metadata)
    }
    
    public func updateMetadataBatch(_ items: [FileMetadata]) {
        do {
            try metadataStore.updateMetadataBatch(items)
        } catch {
            Logger.shared.error(.sync, "Failed to batch update metadata: \(error.localizedDescription)")
        }
    }
    
    public func updateMetadataBatchPersistent(_ items: [FileMetadata]) throws {
        try metadataStore.updateMetadataBatch(items)
    }
    
    public func getMetadata(fileId: String) -> FileMetadata? {
        metadataStore.getMetadata(fileId: fileId)
    }
    
    public func getAllMetadata() -> [FileMetadata] {
        metadataStore.getAllMetadata()
    }
    
    public func removeMetadata(fileId: String) {
        metadataStore.removeMetadata(fileId: fileId)
    }
    
    public func moveMetadata(
        from oldFileId: String,
        to newFileId: String,
        newParentId: String,
        newName: String,
        newRemotePath: String,
        fallbackStatus: SyncStatus
    ) {
        metadataStore.moveMetadata(
            from: oldFileId,
            to: newFileId,
            newParentId: newParentId,
            newName: newName,
            newRemotePath: newRemotePath,
            fallbackStatus: fallbackStatus
        )
    }
    
    public func moveDirectoryMetadata(
        from oldDirId: String,
        to newDirId: String,
        newParentId: String,
        newName: String,
        newRemotePath: String
    ) {
        metadataStore.moveDirectoryMetadata(
            from: oldDirId,
            to: newDirId,
            newParentId: newParentId,
            newName: newName,
            newRemotePath: newRemotePath
        )
    }
    
    public func removeDirectoryMetadata(forDirectoryPrefix dirPrefix: String) {
        metadataStore.removeDirectoryMetadata(forDirectoryPrefix: dirPrefix)
    }
    
    public func getPendingSyncFiles() -> [FileMetadata] {
        metadataStore.getPendingSyncFiles()
    }
    

}
