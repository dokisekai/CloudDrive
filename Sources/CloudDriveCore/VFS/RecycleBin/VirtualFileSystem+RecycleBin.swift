//
//  VirtualFileSystem+RecycleBin.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  回收站目录管理与真实移动逻辑（云端执行真实 MOVE，本地物理清理缓存释放空间）
//

import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CloudDrivePersistence
import CloudDriveRecovery
import CloudDriveVFS
import CloudDriveCache
import CloudDriveSync

extension VirtualFileSystem {
    /// 获取当前已创建的「回收站」目录（若未创建则返回 nil）
    public func getRecycleBinDirectory() -> VirtualFileItem? {
        guard let children = try? database.listChildren(parentId: "ROOT") else { return nil }
        return children.first(where: { $0.isDirectory && $0.name == RecycleBinConstants.directoryName })
    }
    
    /// 获取或创建根目录下的「回收站」目录
    public func getOrCreateRecycleBinDirectory() async throws -> VirtualFileItem {
        if let existing = getRecycleBinDirectory() {
            return existing
        }
        guard let provider = activeProvider else {
            throw VFSError.vaultNotFound("No active vault mounted")
        }
        return try await provider.createDirectory(name: RecycleBinConstants.directoryName, parentId: "ROOT")
    }
    
    /// 判断指定目录 ID 是否为「回收站」目录
    public func isRecycleBinDirectory(id: String) -> Bool {
        guard let bin = getRecycleBinDirectory() else { return false }
        return bin.id == id
    }
    
    /// 判断指定文件是否已在「回收站」内部（支持任意多层子目录嵌套判断）
    public func isItemInRecycleBin(item: VirtualFileItem) -> Bool {
        guard let bin = getRecycleBinDirectory() else { return false }
        if item.id == bin.id { return true }
        if item.parentId == bin.id { return true }
        var currentParentId = item.parentId
        var depth = 0
        while currentParentId != "ROOT" && currentParentId != "/" && !currentParentId.isEmpty && depth < 20 {
            if currentParentId == bin.id { return true }
            guard let parent = try? database.getDirectory(id: currentParentId), let nextParent = parent.parentId else { break }
            currentParentId = nextParent
            depth += 1
        }
        return false
    }
    
    /// 软删除：将文件移入「回收站」目录（云端真实执行 MOVE，本地立即物理清理缓存释放空间）
    @discardableResult
    public func moveToRecycleBin(item: VirtualFileItem) async throws -> VirtualFileItem {
        guard let provider = activeProvider else {
            throw VFSError.vaultNotFound("No active vault mounted")
        }
        
        let binDir = try await getOrCreateRecycleBinDirectory()
        guard item.id != binDir.id else {
            throw VFSError.fileOperationFailed("无法将回收站目录本身移入回收站")
        }
        
        // 0. 若开启了快照备份，先留存一份轻量克隆副本以支持即时还原
        var backupPath: String? = nil
        let targetVault = vaultId ?? "default"
        if !item.isDirectory, RecycleBinConfig.isLocalSnapshotEnabled {
            let cachedURL = cacheManager.localPath(for: item.id)
            if FileManager.default.fileExists(atPath: cachedURL.path) {
                let backupDir = CloudDrivePaths.sharedDirectory
                    .appendingPathComponent("RecycleBinCache", isDirectory: true)
                    .appendingPathComponent(targetVault, isDirectory: true)
                try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
                let destURL = backupDir.appendingPathComponent("\(UUID().uuidString)_\(item.name)")
                if copyfile(cachedURL.path, destURL.path, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0 {
                    backupPath = destURL.path
                } else if (try? FileManager.default.copyItem(at: cachedURL, to: destURL)) != nil {
                    backupPath = destURL.path
                }
            }
        }
        
        // 1. 同名冲突自动重命名（例如 notes (1).txt）
        var targetName = item.name
        let existingInBin = (try? database.listChildren(parentId: binDir.id)) ?? []
        if existingInBin.contains(where: { $0.name.localizedCaseInsensitiveCompare(targetName) == .orderedSame && $0.id != item.id }) {
            let ext = (targetName as NSString).pathExtension
            let base = (targetName as NSString).deletingPathExtension
            var counter = 1
            while existingInBin.contains(where: { $0.name.localizedCaseInsensitiveCompare(targetName) == .orderedSame && $0.id != item.id }) {
                targetName = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
                counter += 1
            }
        }
        
        // 2. 云端与底层驱动真实执行目录移动（MOVE）
        let moved = try await provider.moveItem(itemId: item.id, newParentId: binDir.id, newName: targetName)
        
        // 3. 本地立即物理删除缓存文件，彻底清空释放 Mac 本地磁盘空间！
        if !item.isDirectory {
            try? cacheManager.removeCachedFile(fileId: moved.id)
            try? cacheManager.removeCachedFile(fileId: item.id)
        } else {
            cacheManager.removeDirectoryCache(forDirectoryPrefix: moved.id)
            cacheManager.removeDirectoryCache(forDirectoryPrefix: item.id)
        }
        
        // 4. 更新同步元数据为纯云端状态（无本地副本，访达展示云朵图标）
        if var meta = syncManager.getMetadata(fileId: moved.id) {
            meta.localPath = nil
            meta.syncStatus = .cloudOnly
            syncManager.updateMetadata(meta)
        }
        
        // 5. 记录到 RecycleBinStore，供桌面端 App 统计和保留期限管理
        let binItem = RecycleBinItem(
            id: UUID().uuidString,
            vaultId: targetVault,
            fileId: moved.id,
            name: moved.name,
            originalParentId: item.parentId,
            originalRemotePath: item.remotePath ?? "",
            isDirectory: moved.isDirectory,
            size: moved.size,
            deletedAt: Date(),
            localBackupPath: backupPath
        )
        try? RecycleBinStore.shared.save(binItem)
        
        Logger.shared.info(.fileOps, "🗑️ [RecycleBin] File moved to recycle bin folder and local cache purged: \(moved.name) (ID: \(moved.id))")
        return moved
    }
    
    /// 清空回收站：永久硬删除回收站目录下的全部文件与子文件夹，彻底释放云端空间
    public func emptyTrash() async throws {
        guard let provider = activeProvider else {
            throw VFSError.vaultNotFound("No active vault mounted")
        }
        guard let binDir = getRecycleBinDirectory() else { return }
        let children = (try? database.listChildren(parentId: binDir.id)) ?? []
        for child in children {
            try? await provider.delete(itemId: child.id)
        }
        if let targetVault = vaultId {
            try? RecycleBinStore.shared.deleteByVault(vaultId: targetVault)
        }
    }
}
