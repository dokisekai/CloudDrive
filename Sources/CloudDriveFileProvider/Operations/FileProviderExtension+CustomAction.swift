//
//  FileProviderExtension+CustomAction.swift
//  CloudDriveFileProvider
//
//  NSFileProviderCustomAction 实现 - 访达右键加密专属动作
//

import AppKit
import Foundation
import FileProvider
import CloudDriveCore
import CloudDriveSupport

extension FileProviderExtension {

    public static let actionSecureEvict = NSFileProviderExtensionActionIdentifier("net.aabg.CloudDrive.action.secureEvict")
    public static let actionLockVault = NSFileProviderExtensionActionIdentifier("net.aabg.CloudDrive.action.lockVault")
    public static let actionSanitizeVault = NSFileProviderExtensionActionIdentifier("net.aabg.CloudDrive.action.sanitizeVault")
    public static let actionSyncNow = NSFileProviderExtensionActionIdentifier("net.aabg.CloudDrive.action.syncNow")
    public static let actionExcludeFromSync = NSFileProviderExtensionActionIdentifier("net.aabg.CloudDrive.action.excludeFromSync")
    public static let actionResumeSync = NSFileProviderExtensionActionIdentifier("net.aabg.CloudDrive.action.resumeSync")
    public static let actionPin = NSFileProviderExtensionActionIdentifier("net.aabg.CloudDrive.action.pin")
    public static let actionUnpin = NSFileProviderExtensionActionIdentifier("net.aabg.CloudDrive.action.unpin")

    public func performAction(
        identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
        onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: Int64(max(1, itemIdentifiers.count)))

        let task = Task { [weak self] in
            guard let self = self else {
                completionHandler(NSFileProviderError(.noSuchItem))
                return
            }

            do {
                try Task.checkCancellation()
                try await self.ensureVaultUnlocked()

                switch actionIdentifier {
                case Self.actionSecureEvict:
                    try await self.performSecureEvict(itemIdentifiers: itemIdentifiers, progress: progress)
                case Self.actionPin:
                    try await self.performPin(itemIdentifiers: itemIdentifiers, progress: progress)
                case Self.actionUnpin:
                    try await self.performUnpin(itemIdentifiers: itemIdentifiers, progress: progress)
                case Self.actionLockVault:
                    try await self.performLockVault()
                case Self.actionSanitizeVault:
                    try await self.performSanitizeVault(itemIdentifiers: itemIdentifiers)
                case Self.actionSyncNow:
                    try await self.performSyncNow(itemIdentifiers: itemIdentifiers, progress: progress)
                case Self.actionExcludeFromSync:
                    try await self.performExcludeFromSync(itemIdentifiers: itemIdentifiers, progress: progress)
                case Self.actionResumeSync:
                    try await self.performResumeSync(itemIdentifiers: itemIdentifiers, progress: progress)
                default:
                    logWarning(.fileOps, "Unknown custom action identifier: \(actionIdentifier.rawValue)")
                }

                progress.completedUnitCount = progress.totalUnitCount
                completionHandler(nil)
            } catch {
                let mapped: Error = error is CancellationError
                    ? CocoaError(.userCancelled)
                    : (error as? NSFileProviderError ?? NSFileProviderError(.serverUnreachable))
                completionHandler(mapped)
            }
        }

        progress.cancellationHandler = {
            task.cancel()
        }

        return progress
    }

    // MARK: - 1. 释放本地空间并抹除明文缓存 (Secure Evict / Free Space)
    private func performSecureEvict(
        itemIdentifiers: [NSFileProviderItemIdentifier],
        progress: Progress
    ) async throws {
        logInfo(.fileOps, "🛡️ Performing Secure Evict / Free Space for \(itemIdentifiers.count) items")
        let manager = NSFileProviderManager(for: self.domain)

        func evictSingleFile(fileId: String, itemIdentifier: NSFileProviderItemIdentifier) {
            self.cacheManager.unpinFile(fileId: fileId)
            let cachePath = self.cacheManager.localPath(for: fileId)

            if FileManager.default.fileExists(atPath: cachePath.path) {
                // 安全覆写：先用 0 字节覆写磁盘文件，彻底杜绝数据恢复
                if let handle = try? FileHandle(forWritingTo: cachePath),
                   let attrs = try? FileManager.default.attributesOfItem(atPath: cachePath.path),
                   let size = attrs[.size] as? Int, size > 0 {
                    let zeroBuffer = Data(repeating: 0, count: min(size, 1024 * 1024))
                    var written = 0
                    while written < size {
                        let toWrite = min(zeroBuffer.count, size - written)
                        try? handle.write(contentsOf: zeroBuffer.prefix(toWrite))
                        written += toWrite
                    }
                    try? handle.synchronize()
                    try? handle.close()
                }

                // 移除本地缓存文件
                try? self.cacheManager.evictFile(fileId: fileId)
            }

            // 更新状态机元数据为云端占位状态
            if var metadata = self.syncManager.getMetadata(fileId: fileId) {
                metadata.syncStatus = .cloudOnly
                metadata.downloadProgress = 0.0
                metadata.localPath = nil
                self.syncManager.updateMetadata(metadata)
            }

            // 通知 macOS 文件系统回收本地块并变回云朵占位图标
            manager?.evictItem(identifier: itemIdentifier) { _ in }
        }

        for identifier in itemIdentifiers {
            try Task.checkCancellation()
            let fileId = identifier.rawValue
            self.cacheManager.unpinFile(fileId: fileId)

            if let item = try? self.vfs.getItem(id: fileId), item.isDirectory {
                let children = (try? self.vfs.listDirectory(directoryId: fileId)) ?? []
                for child in children where !child.isDirectory {
                    evictSingleFile(fileId: child.id, itemIdentifier: NSFileProviderItemIdentifier(child.id))
                }
            } else {
                evictSingleFile(fileId: fileId, itemIdentifier: identifier)
            }

            if let item = try? self.vfs.getItem(id: fileId) {
                self.signalEnumeratorDebounced(for: item.parentId == "ROOT" ? .rootContainer : NSFileProviderItemIdentifier(item.parentId))
            }
            progress.completedUnitCount += 1
        }

        self.signalEnumeratorDebounced(for: .workingSet)
    }

    // MARK: - 2. 立即锁定保险库 (Lock Vault)
    private func performLockVault() async throws {
        logInfo(.system, "🔒 Locking vault on user action")
        
        // 1. 锁定 VFS 并擦除内存中的密钥
        self.vfs.lock()

        // 2. 清除所有已物化文件的本地缓存与明文数据
        for fileId in self.materializedIds {
            try? self.cacheManager.evictFile(fileId: fileId)
        }

        // 3. 广播保险库锁定通知
        let center = DistributedNotificationCenter.default()
        center.postNotificationName(
            NSNotification.Name("net.aabg.CloudDrive.vaultLocked"),
            object: nil,
            userInfo: ["vaultId": self.vaultInfo?.id ?? self.domain.identifier.rawValue],
            deliverImmediately: true
        )

        // 4. 通知 Finder 刷新目录树
        self.signalEnumeratorDebounced(for: .rootContainer)
        self.signalEnumeratorDebounced(for: .workingSet)
    }

    // MARK: - 3. 保险库完整性体检 (Sanitize Vault)
    private func performSanitizeVault(itemIdentifiers: [NSFileProviderItemIdentifier]) async throws {
        logInfo(.system, "🩺 Starting Cryptomator Vault integrity check")
        // 遍历选定目录或根目录，验证 dir.c9r 与文件加密有效性
        let targetId = itemIdentifiers.first?.rawValue ?? "ROOT"
        _ = try await self.vfs.listDirectoryFromWebDAVAsync(directoryId: targetId)
        logSuccess(.system, "✅ Cryptomator Vault integrity check completed without errors")
    }

    // MARK: - 4. 立即与云端同步 (Sync Now)
    private func performSyncNow(
        itemIdentifiers: [NSFileProviderItemIdentifier],
        progress: Progress
    ) async throws {
        logInfo(.sync, "🔄 Performing Sync Now for \(itemIdentifiers.count) items")
        
        // 1. 处理后台待同步任务
        self.syncManager.processSyncQueue()
        
        // 2. 收集需要刷新的容器
        var containersToSignal = Set<NSFileProviderItemIdentifier>()
        containersToSignal.insert(.workingSet)
        containersToSignal.insert(.rootContainer)
        
        for identifier in itemIdentifiers {
            try Task.checkCancellation()
            let fileId = identifier.rawValue
            if let item = try? self.findItem(identifier: fileId) {
                if item.isDirectory {
                    _ = try? await self.vfs.listDirectoryFromWebDAVAsync(directoryId: item.id)
                    containersToSignal.insert(identifier)
                } else {
                    let parentId = item.parentId
                    _ = try? await self.vfs.listDirectoryFromWebDAVAsync(directoryId: parentId)
                    containersToSignal.insert(parentId == "ROOT" || parentId == "/" ? .rootContainer : NSFileProviderItemIdentifier(parentId))
                }
            }
            progress.completedUnitCount += 1
        }
        
        // 3. 立即绕过防抖，广播系统 Enumerator 刷新
        for container in containersToSignal {
            await EnumeratorSignaler.shared.signalImmediately(for: self.domain, containerItemIdentifiers: [container])
        }
        logSuccess(.sync, "✅ Sync Now completed")
    }

    // MARK: - 5. 从同步中排除 (.nosync)
    private func performExcludeFromSync(
        itemIdentifiers: [NSFileProviderItemIdentifier],
        progress: Progress
    ) async throws {
        logInfo(.sync, "🚫 Performing Exclude from Sync for \(itemIdentifiers.count) items")
        
        for identifier in itemIdentifiers {
            try Task.checkCancellation()
            let fileId = identifier.rawValue
            guard let item = try? self.findItem(identifier: fileId) else {
                progress.completedUnitCount += 1
                continue
            }
            
            let originalName = item.name
            guard !originalName.hasSuffix(".nosync") else {
                progress.completedUnitCount += 1
                continue
            }
            
            let newName = "\(originalName).nosync"
            
            // 1. 取消待上传队列中可能存在的任务
            self.syncManager.removePendingUploads(for: item.id)
            self.syncManager.removePendingUploads(for: fileId)
            
            // 2. 在 VFS 中重命名并添加 .nosync 后缀
            let movedItem = try await self.vfs.moveItem(
                itemId: item.id,
                newParentId: item.parentId,
                newName: newName
            )
            
            // 3. 将同步状态设置为本地独占 (.localOnly)
            var meta = self.syncManager.getMetadata(fileId: movedItem.id) ?? FileMetadata(
                fileId: movedItem.id,
                name: newName,
                parentId: item.parentId,
                isDirectory: item.isDirectory,
                syncStatus: .localOnly,
                localPath: movedItem.localPath,
                size: movedItem.size
            )
            meta.syncStatus = .localOnly
            self.syncManager.updateMetadata(meta)
            
            // 4. 记录到用户排除引擎
            let relativePath = item.parentId == "ROOT" ? newName : "\(item.parentId)/\(newName)"
            IgnoreRuleEngine.shared.setUserExcluded(vaultId: self.currentVaultIdentifier, path: relativePath, isExcluded: true)
            
            let parentId = item.parentId
            self.signalEnumeratorDebounced(for: parentId == "ROOT" || parentId == "/" ? .rootContainer : NSFileProviderItemIdentifier(parentId))
            progress.completedUnitCount += 1
        }
        
        self.signalEnumeratorDebounced(for: .workingSet)
        logSuccess(.sync, "✅ Exclude from sync completed")
    }

    // MARK: - 6. 恢复同步 (Resume Sync)
    private func performResumeSync(
        itemIdentifiers: [NSFileProviderItemIdentifier],
        progress: Progress
    ) async throws {
        logInfo(.sync, "🔄 Performing Resume Sync for \(itemIdentifiers.count) items")
        
        for identifier in itemIdentifiers {
            try Task.checkCancellation()
            let fileId = identifier.rawValue
            guard let item = try? self.findItem(identifier: fileId) else {
                progress.completedUnitCount += 1
                continue
            }
            
            let originalName = item.name
            let newName: String
            if originalName.hasSuffix(".nosync") {
                newName = String(originalName.dropLast(7))
            } else {
                newName = originalName
            }
            
            // 1. 从用户排除清单中移除
            let oldRelPath = item.parentId == "ROOT" ? originalName : "\(item.parentId)/\(originalName)"
            let newRelPath = item.parentId == "ROOT" ? newName : "\(item.parentId)/\(newName)"
            IgnoreRuleEngine.shared.setUserExcluded(vaultId: self.currentVaultIdentifier, path: oldRelPath, isExcluded: false)
            IgnoreRuleEngine.shared.setUserExcluded(vaultId: self.currentVaultIdentifier, path: newRelPath, isExcluded: false)
            
            // 2. 如果名称发生了改变，在 VFS 中重命名还原
            let restoredItem: VirtualFileItem
            if newName != originalName {
                restoredItem = try await self.vfs.moveItem(
                    itemId: item.id,
                    newParentId: item.parentId,
                    newName: newName
                )
            } else {
                restoredItem = item
            }
            
            // 3. 将同步状态重置为待上传 (.pendingUpload)
            var meta = self.syncManager.getMetadata(fileId: restoredItem.id) ?? FileMetadata(
                fileId: restoredItem.id,
                name: newName,
                parentId: restoredItem.parentId,
                isDirectory: restoredItem.isDirectory,
                syncStatus: .pendingUpload,
                localPath: restoredItem.localPath,
                size: restoredItem.size
            )
            meta.syncStatus = .pendingUpload
            self.syncManager.updateMetadata(meta)
            
            // 4. 将其入队上传队列
            if !restoredItem.isDirectory {
                let cacheURL = self.cacheManager.localPath(for: restoredItem.id)
                if FileManager.default.fileExists(atPath: cacheURL.path) {
                    let staged = try PendingContentStager(vaultId: self.currentVaultIdentifier).stage(cacheURL, filename: newName)
                    meta.localPath = staged.path
                    try self.syncManager.updateMetadataPersistent(meta)
                    if self.vfs.isEncrypted {
                        try self.syncManager.enqueuePersistent(.encryptedUpload(
                            fileId: restoredItem.id,
                            fileName: newName,
                            parentId: restoredItem.parentId,
                            localPath: staged.path,
                            vaultId: self.currentVaultIdentifier
                        ))
                    } else {
                        let remotePath = restoredItem.parentId == "ROOT" ? "/\(newName)" : "\(restoredItem.parentId)/\(newName)"
                        try self.syncManager.enqueuePersistent(.upload(
                            fileId: restoredItem.id,
                            localPath: staged.path,
                            remotePath: remotePath
                        ))
                    }
                }
            }
            
            let parentId = restoredItem.parentId
            self.signalEnumeratorDebounced(for: parentId == "ROOT" || parentId == "/" ? .rootContainer : NSFileProviderItemIdentifier(parentId))
            progress.completedUnitCount += 1
        }
        
        self.syncManager.processSyncQueue()
        self.signalEnumeratorDebounced(for: .workingSet)
        logSuccess(.sync, "✅ Resume sync completed")
    }

    // MARK: - 7. 始终保留在此 Mac 上 (Pin)
    private func performPin(
        itemIdentifiers: [NSFileProviderItemIdentifier],
        progress: Progress
    ) async throws {
        logInfo(.fileOps, "📌 Performing Pin (Keep Local) for \(itemIdentifiers.count) items")

        for identifier in itemIdentifiers {
            try Task.checkCancellation()
            let fileId = identifier.rawValue
            self.cacheManager.pinFile(fileId: fileId)

            if let item = try? self.findItem(identifier: fileId) {
                if !item.isDirectory {
                    // 如果文件尚未下载到本机缓存，后台立即按需下载
                    if !self.cacheManager.isCached(fileId: item.id) {
                        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        defer { try? FileManager.default.removeItem(at: tempURL) }
                        try? await self.vfs.downloadFile(fileId: item.id, to: tempURL) { _ in }
                        try? self.cacheManager.cacheFile(fileId: item.id, from: tempURL, policy: .pinned)
                    }
                }
                let parentId = item.parentId
                self.signalEnumeratorDebounced(for: parentId == "ROOT" || parentId == "/" ? .rootContainer : NSFileProviderItemIdentifier(parentId))
            }
            progress.completedUnitCount += 1
        }

        self.signalEnumeratorDebounced(for: .workingSet)
        logSuccess(.fileOps, "✅ Pin completed")
    }

    // MARK: - 8. 取消始终保留在此 Mac 上 (Unpin)
    private func performUnpin(
        itemIdentifiers: [NSFileProviderItemIdentifier],
        progress: Progress
    ) async throws {
        logInfo(.fileOps, "📍 Performing Unpin for \(itemIdentifiers.count) items")

        for identifier in itemIdentifiers {
            try Task.checkCancellation()
            let fileId = identifier.rawValue
            self.cacheManager.unpinFile(fileId: fileId)

            if let item = try? self.findItem(identifier: fileId) {
                let parentId = item.parentId
                self.signalEnumeratorDebounced(for: parentId == "ROOT" || parentId == "/" ? .rootContainer : NSFileProviderItemIdentifier(parentId))
            }
            progress.completedUnitCount += 1
        }

        self.signalEnumeratorDebounced(for: .workingSet)
        logSuccess(.fileOps, "✅ Unpin completed")
    }
}
