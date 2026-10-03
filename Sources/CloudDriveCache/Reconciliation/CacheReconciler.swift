//
//  CacheReconciler.swift
//  CloudDriveCache
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  磁盘物理文件与元数据对账器
//

import Foundation
import CloudDriveContracts

/// 磁盘与元数据一致性对账器
public final class CacheReconciler: Sendable {
    private let storage: CacheDiskStorageProtocol
    private let metadataStore: CacheMetadataStoreProtocol
    
    public init(
        storage: CacheDiskStorageProtocol,
        metadataStore: CacheMetadataStoreProtocol
    ) {
        self.storage = storage
        self.metadataStore = metadataStore
    }
    
    /// 执行磁盘与元数据对账
    public func reconcile() {
        let diskFiles = storage.listAllDiskFiles()
        let normalizedDiskFiles = Set(diskFiles.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 })
        let currentMetadata = metadataStore.getAllMetadata()
        var updated = false
        
        // 1. 扫描磁盘上存在但元数据中缺失的文件：补齐元数据
        for fileId in diskFiles {
            let cleanId = fileId.hasPrefix("/") ? String(fileId.dropFirst()) : fileId
            if currentMetadata[cleanId] == nil && currentMetadata["/\(cleanId)"] == nil {
                let size = storage.fileSize(for: fileId)
                let now = Date()
                metadataStore.set(CacheMetadata(
                    fileId: cleanId,
                    size: size,
                    downloadedAt: now,
                    lastAccessedAt: now,
                    policy: .automatic
                ))
                updated = true
            }
        }
        
        // 2. 清除元数据中存在但物理磁盘文件已丢失的假元数据
        for (key, meta) in currentMetadata {
            let cleanKey = key.hasPrefix("/") ? String(key.dropFirst()) : key
            if !normalizedDiskFiles.contains(cleanKey) && meta.policy != .pinned {
                _ = metadataStore.remove(for: key)
                _ = metadataStore.remove(for: cleanKey)
                updated = true
            }
        }
        
        if updated {
            metadataStore.save(immediate: true)
        }
    }
}
