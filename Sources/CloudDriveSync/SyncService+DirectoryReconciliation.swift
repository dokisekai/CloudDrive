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
    public func syncDirectory(directoryId: String, localPath: String, remotePath: String) async throws -> [FileMetadata] {
        guard let storageClient = getStorageClient() else {
            throw SyncError.storageNotConfigured
        }
        
        var syncedFiles: [FileMetadata] = []
        var remoteFiles: [StorageResource] = []
        
        if networkMonitor.isOnline {
            do {
                remoteFiles = try await storageClient.listDirectory(path: remotePath)
            } catch {
                // An unavailable/incomplete snapshot must never mean an empty cloud.
                throw error
            }
        } else {
            throw SyncError.networkUnavailable
        }
        
        var localFiles: [URL] = []
        if fileManager.fileExists(atPath: localPath) {
            do {
                localFiles = try fileManager.contentsOfDirectory(at: URL(fileURLWithPath: localPath), includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])
            } catch {
                Logger.shared.warning(.sync, "Failed to fetch local files: \(error.localizedDescription)")
            }
        }
        
        let remoteFileNames = Set(remoteFiles.map { $0.displayName })
        let localFileNames = Set(localFiles.map { $0.lastPathComponent })
        
        let cloudOnlyFiles = remoteFileNames.subtracting(localFileNames)
        for fileName in cloudOnlyFiles {
            if let resource = remoteFiles.first(where: { $0.displayName == fileName }) {
                let fileId = "\(remotePath)/\(fileName)"
                let metadata = FileMetadata(
                    fileId: fileId,
                    name: fileName,
                    parentId: directoryId,
                    isDirectory: resource.isDirectory,
                    syncStatus: .cloudOnly,
                    remotePath: resource.path,
                    size: resource.contentLength,
                    remoteModifiedAt: resource.lastModified,
                    etag: resource.etag
                )
                updateMetadata(metadata)
                syncedFiles.append(metadata)
            }
        }
        
        let localOnlyFiles = localFileNames.subtracting(remoteFileNames)
        for fileName in localOnlyFiles {
            if let fileURL = localFiles.first(where: { $0.lastPathComponent == fileName }) {
                let fileId = "\(remotePath)/\(fileName)"
                let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                let modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                
                let metadata = FileMetadata(
                    fileId: fileId,
                    name: fileName,
                    parentId: directoryId,
                    isDirectory: isDirectory,
                    syncStatus: .localOnly,
                    localPath: fileURL.path,
                    size: Int64(size),
                    localModifiedAt: modifiedAt
                )
                updateMetadata(metadata)
                syncedFiles.append(metadata)
                
                if networkMonitor.isOnline {
                    let remoteFilePath = "\(remotePath)/\(fileName)"
                    if isDirectory {
                        addToSyncQueue(.createDirectory(directoryId: fileId, name: fileName, parentId: directoryId, remotePath: remoteFilePath))
                    } else {
                        addToSyncQueue(.upload(fileId: fileId, localPath: fileURL.path, remotePath: remoteFilePath))
                    }
                }
            }
        }
        
        let commonFiles = remoteFileNames.intersection(localFileNames)
        for fileName in commonFiles {
            if let resource = remoteFiles.first(where: { $0.displayName == fileName }),
               let fileURL = localFiles.first(where: { $0.lastPathComponent == fileName }) {
                let fileId = "\(remotePath)/\(fileName)"
                let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                let localModifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                
                let existingMeta = getMetadata(fileId: fileId)
                let lastSync = existingMeta?.lastSyncTime
                
                var metadata = FileMetadata(
                    fileId: fileId,
                    name: fileName,
                    parentId: directoryId,
                    isDirectory: isDirectory,
                    syncStatus: .synced,
                    localPath: fileURL.path,
                    remotePath: resource.path,
                    size: Int64(size),
                    localModifiedAt: localModifiedAt,
                    remoteModifiedAt: resource.lastModified,
                    etag: resource.etag,
                    lastSyncTime: lastSync
                )
                
                let conflictType = conflictResolver.detectConflict(local: metadata, remote: resource)
                if conflictType != .none || metadata.hasConflict() {
                    metadata.syncStatus = .conflict
                } else if let lastSync {
                    if let localMod = localModifiedAt, localMod > lastSync {
                        metadata.syncStatus = .pendingUpload
                    } else if let remoteMod = resource.lastModified, remoteMod > lastSync {
                        metadata.syncStatus = .cloudOnly
                    }
                } else {
                    if let remoteETag = resource.etag, let existingETag = existingMeta?.etag, remoteETag != existingETag {
                        metadata.syncStatus = .conflict
                    } else if Int64(size) != resource.contentLength {
                        metadata.syncStatus = .conflict
                    }
                }
                
                updateMetadata(metadata)
                syncedFiles.append(metadata)
            }
        }
        
        return syncedFiles
    }
}
