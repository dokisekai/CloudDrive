//
//  ConflictResolver.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  文件冲突解决器 - 智能冲突检测与解决
//

import Foundation

/// 文件冲突解决器
public class ConflictResolver {
    public static let shared = ConflictResolver()
    
    private let syncManager = SyncManager.shared
    private let cacheManager = CacheManager.shared
    private let fileManager = FileManager.default
    
    // 冲突解决策略
    private var defaultResolutionPolicy: ConflictResolutionPolicy = .askUser
    private var customPolicies: [String: ConflictResolutionPolicy] = [:]
    
    // 冲突历史
    private var conflictHistory: [ConflictRecord] = []
    private let historyQueue = DispatchQueue(label: "com.clouddrive.conflict.history")
    
    // 冲突处理回调
    public var onConflict: ((ConflictInfo) -> ConflictResolution)?
    
    private init() {
        Logger.shared.info(.sync, "冲突解决器已初始化")
    }
    
    // MARK: - 冲突检测
    
    /// 检测文件冲突
    public func detectConflict(fileId: String) async -> ConflictInfo? {
        guard let metadata = syncManager.getMetadata(fileId: fileId) else {
            Logger.shared.info(.sync, "文件不存在，无法检测冲突: \(fileId)")
            return nil
        }
        
        // 检查是否需要检测冲突
        guard metadata.syncStatus == .synced else {
            Logger.shared.info(.sync, "文件未同步，跳过冲突检测: \(fileId)")
            return nil
        }
        
        // 检查本地文件是否存在
        let localExists = metadata.localPath != nil && fileManager.fileExists(atPath: metadata.localPath!)
        
        // 检查远程文件是否存在（通过ETag或元数据）
        let remoteExists = metadata.remotePath != nil && metadata.etag != nil && metadata.etag != ""
        
        // 情况1: 仅本地存在
        if localExists && !remoteExists {
            Logger.shared.info(.sync, "文件仅存在于本地: \(fileId)")
            return ConflictInfo(
                fileId: fileId,
                conflictType: .localOnly,
                resolutionPolicy: defaultResolutionPolicy
            )
        }
        
        // 情况2: 仅远程存在
        if !localExists && remoteExists {
            Logger.shared.info(.sync, "文件仅存在于云端: \(fileId)")
            return ConflictInfo(
                fileId: fileId,
                conflictType: .remoteOnly,
                resolutionPolicy: defaultResolutionPolicy
            )
        }
        
        // 情况3: 检查修改时间冲突
        if localExists && remoteExists {
            if let localModified = metadata.localModifiedAt,
               let remoteModified = metadata.remoteModifiedAt,
               let lastSyncTime = metadata.lastSyncTime {
                
                // 检查本地和远程是否在同步后都被修改
                let localModifiedAfterSync = localModified > lastSyncTime
                let remoteModifiedAfterSync = remoteModified > lastSyncTime
                
                if localModifiedAfterSync && remoteModifiedAfterSync {
                    Logger.shared.warning(.sync, "检测到修改冲突: \(fileId)")
                    Logger.shared.info(.sync, "  本地修改时间: \(localModified)")
                    Logger.shared.info(.sync, "  远程修改时间: \(remoteModified)")
                    Logger.shared.info(.sync, "  最后同步时间: \(lastSyncTime)")
                    
                    return ConflictInfo(
                        fileId: fileId,
                        conflictType: .modificationConflict,
                        resolutionPolicy: getResolutionPolicy(for: fileId)
                    )
                }
                
                // 检查内容差异（如果文件类型支持）
                if localModifiedAfterSync || remoteModifiedAfterSync {
                    if await hasContentDifference(fileId: fileId) {
                        Logger.shared.warning(.sync, "检测到内容差异: \(fileId)")
                        return ConflictInfo(
                            fileId: fileId,
                            conflictType: .contentDifference,
                            resolutionPolicy: getResolutionPolicy(for: fileId)
                        )
                    }
                }
            }
        }
        
        Logger.shared.info(.sync, "未检测到冲突: \(fileId)")
        return nil
    }
    
    /// 检查内容差异
    private func hasContentDifference(fileId: String) async -> Bool {
        guard let metadata = syncManager.getMetadata(fileId: fileId),
              let localPath = metadata.localPath,
              let remotePath = metadata.remotePath else {
            return false
        }
        
        // 检查文件大小
        guard let localSize = try? fileManager.attributesOfItem(atPath: localPath)[.size] as? Int64,
              let remoteSize = metadata.size else {
            return false
        }
        
        if localSize != remoteSize {
            Logger.shared.info(.sync, "文件大小不同: 本地 \(localSize) vs 远程 \(remoteSize)")
            return true
        }
        
        // 检查修改时间
        if let localModified = metadata.localModifiedAt,
           let remoteModified = metadata.remoteModifiedAt {
            let timeDiff = abs(localModified.timeIntervalSince(remoteModified))
            if timeDiff > 1.0 { // 超过1秒认为有差异
                Logger.shared.info(.sync, "修改时间不同: 本地 \(localModified) vs 远程 \(remoteModified)")
                return true
            }
        }
        
        return false
    }
    
    /// 批量检测冲突
    public func detectAllConflicts() async -> [ConflictInfo] {
        Logger.shared.info(.sync, "开始批量检测冲突...")
        
        let pendingFiles = syncManager.getPendingSyncFiles()
        var conflicts: [ConflictInfo] = []
        
        for file in pendingFiles {
            if let conflict = await detectConflict(fileId: file.fileId) {
                conflicts.append(conflict)
            }
        }
        
        Logger.shared.info(.sync, "冲突检测完成，发现 \(conflicts.count) 个冲突")
        return conflicts
    }
    
    // MARK: - 冲突解决
    
    /// 解决冲突
    public func resolveConflict(_ conflict: ConflictInfo) async throws -> ConflictResolution {
        Logger.shared.info(.sync, "开始解决冲突: \(conflict.fileId)")
        Logger.shared.info(.sync, "  冲突类型: \(conflict.conflictType)")
        Logger.shared.info(.sync, "  解决策略: \(conflict.resolutionPolicy)")
        
        let resolution: ConflictResolution
        
        switch conflict.conflictType {
        case .localOnly:
            resolution = try await resolveLocalOnlyConflict(conflict)
            
        case .remoteOnly:
            resolution = try await resolveRemoteOnlyConflict(conflict)
            
        case .modificationConflict:
            resolution = try await resolveModificationConflict(conflict)
            
        case .contentDifference:
            resolution = try await resolveContentDifferenceConflict(conflict)
        }
        
        // 记录冲突解决历史
        recordConflictResolution(conflict: conflict, resolution: resolution)
        
        Logger.shared.success(.sync, "冲突已解决: \(conflict.fileId) -> \(resolution)")
        return resolution
    }
    
    /// 解决仅本地存在的冲突
    private func resolveLocalOnlyConflict(_ conflict: ConflictInfo) async throws -> ConflictResolution {
        guard let metadata = syncManager.getMetadata(fileId: conflict.fileId),
              let localPath = metadata.localPath else {
            throw ConflictError.fileNotFound
        }
        
        let policy = conflict.resolutionPolicy
        
        switch policy {
        case .localWins, .askUser:
            // 上传到云端
            if let storageClient = syncManager.getStorageClient() {
                try await storageClient.uploadFile(
                    localURL: URL(fileURLWithPath: localPath),
                    to: conflict.fileId
                ) { _ in }
                
                // 更新元数据
                var updatedMetadata = metadata
                updatedMetadata.syncStatus = .synced
                updatedMetadata.remotePath = conflict.fileId
                updatedMetadata.remoteModifiedAt = Date()
                updatedMetadata.lastSyncTime = Date()
                syncManager.updateMetadata(updatedMetadata)
                
                return ConflictResolution(
                    action: .uploaded,
                    details: "本地文件已上传到云端"
                )
            }
            
        case .remoteWins:
            // 删除本地文件
            try fileManager.removeItem(atPath: localPath)
            syncManager.removeMetadata(fileId: conflict.fileId)
            
            return ConflictResolution(
                action: .deletedLocal,
                details: "本地文件已删除"
            )
            
        case .renameLocal:
            // 重命名为冲突版本
            let newName = generateConflictName(for: localPath)
            try fileManager.moveItem(atPath: localPath, toPath: newName)
            
            var updatedMetadata = metadata
            updatedMetadata.localPath = newName
            syncManager.updateMetadata(updatedMetadata)
            
            return ConflictResolution(
                action: .renamed,
                details: "本地文件已重命名: \(newName)"
            )
        }
        
        throw ConflictError.unsupportedPolicy
    }
    
    /// 解决仅远程存在的冲突
    private func resolveRemoteOnlyConflict(_ conflict: ConflictInfo) async throws -> ConflictResolution {
        let policy = conflict.resolutionPolicy
        
        switch policy {
        case .remoteWins, .askUser:
            // 下载到本地
            if let storageClient = syncManager.getStorageClient() {
                let localURL = cacheManager.localPath(for: conflict.fileId)
                try await storageClient.downloadFile(path: conflict.fileId, to: localURL) { _ in }
                
                // 更新元数据
                if var metadata = syncManager.getMetadata(fileId: conflict.fileId) {
                    metadata.syncStatus = .synced
                    metadata.localPath = localURL.path
                    metadata.localModifiedAt = Date()
                    metadata.lastSyncTime = Date()
                    syncManager.updateMetadata(metadata)
                }
                
                return ConflictResolution(
                    action: .downloaded,
                    details: "云端文件已下载到本地"
                )
            }
            
        case .localWins:
            // 删除远程文件
            if let storageClient = syncManager.getStorageClient() {
                try await storageClient.delete(path: conflict.fileId)
                syncManager.removeMetadata(fileId: conflict.fileId)
                
                return ConflictResolution(
                    action: .deletedRemote,
                    details: "云端文件已删除"
                )
            }
            
        case .renameLocal:
            // 不适用
            throw ConflictError.unsupportedPolicy
        }
        
        throw ConflictError.unsupportedPolicy
    }
    
    /// 解决修改冲突
    private func resolveModificationConflict(_ conflict: ConflictInfo) async throws -> ConflictResolution {
        guard let metadata = syncManager.getMetadata(fileId: conflict.fileId),
              let localPath = metadata.localPath else {
            throw ConflictError.fileNotFound
        }
        
        let policy = conflict.resolutionPolicy
        
        switch policy {
        case .localWins, .askUser:
            // 上传本地版本
            if let storageClient = syncManager.getStorageClient() {
                try await storageClient.uploadFile(
                    localURL: URL(fileURLWithPath: localPath),
                    to: conflict.fileId
                ) { _ in }
                
                var updatedMetadata = metadata
                updatedMetadata.syncStatus = .synced
                updatedMetadata.remoteModifiedAt = Date()
                updatedMetadata.lastSyncTime = Date()
                syncManager.updateMetadata(updatedMetadata)
                
                return ConflictResolution(
                    action: .uploaded,
                    details: "本地版本已覆盖云端版本"
                )
            }
            
        case .remoteWins:
            // 下载远程版本
            if let storageClient = syncManager.getStorageClient() {
                let localURL = cacheManager.localPath(for: conflict.fileId)
                try await storageClient.downloadFile(path: conflict.fileId, to: localURL) { _ in }
                
                var updatedMetadata = metadata
                updatedMetadata.syncStatus = .synced
                updatedMetadata.localModifiedAt = Date()
                updatedMetadata.lastSyncTime = Date()
                syncManager.updateMetadata(updatedMetadata)
                
                return ConflictResolution(
                    action: .downloaded,
                    details: "云端版本已覆盖本地版本"
                )
            }
            
        case .renameLocal:
            // 重命名本地版本，然后下载远程版本
            let newName = generateConflictName(for: localPath)
            try fileManager.moveItem(atPath: localPath, toPath: newName)
            
            // 下载远程版本
            if let storageClient = syncManager.getStorageClient() {
                let localURL = cacheManager.localPath(for: conflict.fileId)
                try await storageClient.downloadFile(path: conflict.fileId, to: localURL) { _ in }
                
                var updatedMetadata = metadata
                updatedMetadata.localPath = localURL.path
                updatedMetadata.syncStatus = .synced
                updatedMetadata.lastSyncTime = Date()
                syncManager.updateMetadata(updatedMetadata)
            }
            
            return ConflictResolution(
                action: .merged,
                details: "本地文件已重命名为: \(newName)，远程文件已下载"
            )
        }
        
        throw ConflictError.unsupportedPolicy
    }
    
    /// 解决内容差异冲突
    private func resolveContentDifferenceConflict(_ conflict: ConflictInfo) async throws -> ConflictResolution {
        // 与修改冲突相同处理
        return try await resolveModificationConflict(conflict)
    }
    
    // MARK: - 辅助方法
    
    /// 生成冲突文件名
    private func generateConflictName(for path: String) -> String {
        let fileURL = URL(fileURLWithPath: path)
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let fileExt = fileURL.pathExtension
        
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let conflictName = "\(fileName)_conflict_\(timestamp)"
        
        if fileExt.isEmpty {
            return "\(fileURL.deletingLastPathComponent().path)/\(conflictName)"
        } else {
            return "\(fileURL.deletingLastPathComponent().path)/\(conflictName).\(fileExt)"
        }
    }
    
    /// 获取文件的解决策略
    private func getResolutionPolicy(for fileId: String) -> ConflictResolutionPolicy {
        if let customPolicy = customPolicies[fileId] {
            return customPolicy
        }
        return defaultResolutionPolicy
    }
    
    /// 设置默认解决策略
    public func setDefaultResolutionPolicy(_ policy: ConflictResolutionPolicy) {
        defaultResolutionPolicy = policy
        Logger.shared.info(.sync, "默认冲突解决策略已设置为: \(policy)")
    }
    
    /// 设置特定文件的解决策略
    public func setResolutionPolicy(for fileId: String, policy: ConflictResolutionPolicy) {
        customPolicies[fileId] = policy
        Logger.shared.info(.sync, "文件 \(fileId) 的冲突解决策略已设置为: \(policy)")
    }
    
    /// 清除自定义策略
    public func clearCustomPolicy(for fileId: String) {
        customPolicies.removeValue(forKey: fileId)
        Logger.shared.info(.sync, "已清除文件 \(fileId) 的自定义策略")
    }
    
    // MARK: - 历史记录
    
    /// 记录冲突解决
    private func recordConflictResolution(conflict: ConflictInfo, resolution: ConflictResolution) {
        let record = ConflictRecord(
            fileId: conflict.fileId,
            conflictType: conflict.conflictType,
            resolution: resolution,
            timestamp: Date()
        )
        
        historyQueue.async {
            self.conflictHistory.append(record)
            
            // 限制历史记录数量
            if self.conflictHistory.count > 1000 {
                self.conflictHistory.removeFirst(self.conflictHistory.count - 1000)
            }
        }
    }
    
    /// 获取冲突历史
    public func getConflictHistory(limit: Int = 100) -> [ConflictRecord] {
        return historyQueue.sync {
            let count = min(limit, conflictHistory.count)
            return Array(conflictHistory.suffix(count))
        }
    }
    
    /// 清除历史记录
    public func clearHistory() {
        historyQueue.sync {
            conflictHistory.removeAll()
        }
        Logger.shared.info(.sync, "冲突历史已清除")
    }
}

// MARK: - 数据类型

/// 冲突类型
public enum ConflictType {
    case localOnly           // 仅本地存在
    case remoteOnly          // 仅远程存在
    case modificationConflict // 修改冲突（本地和远程都被修改）
    case contentDifference   // 内容差异
}

/// 冲突解决策略
public enum ConflictResolutionPolicy {
    case localWins   // 本地优先
    case remoteWins  // 云端优先
    case renameLocal // 重命名本地文件
    case askUser     // 询问用户
}

/// 冲突信息
public struct ConflictInfo {
    public let fileId: String
    public let conflictType: ConflictType
    public let resolutionPolicy: ConflictResolutionPolicy
    public let timestamp: Date
    
    public init(fileId: String, conflictType: ConflictType, resolutionPolicy: ConflictResolutionPolicy) {
        self.fileId = fileId
        self.conflictType = conflictType
        self.resolutionPolicy = resolutionPolicy
        self.timestamp = Date()
    }
}

/// 冲突解决
public struct ConflictResolution {
    public enum Action {
        case uploaded       // 上传了本地版本
        case downloaded     // 下载了远程版本
        case deletedLocal   // 删除了本地文件
        case deletedRemote  // 删除了远程文件
        case renamed        // 重命名了文件
        case merged         // 合并了文件
        case ignored        // 忽略了冲突
    }
    
    public let action: Action
    public let details: String
    public let timestamp: Date
    
    public init(action: Action, details: String) {
        self.action = action
        self.details = details
        self.timestamp = Date()
    }
}

/// 冲突记录
public struct ConflictRecord {
    public let fileId: String
    public let conflictType: ConflictType
    public let resolution: ConflictResolution
    public let timestamp: Date
}

/// 冲突错误
public enum ConflictError: Error, LocalizedError {
    case fileNotFound
    case unsupportedPolicy
    case resolutionFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "文件不存在"
        case .unsupportedPolicy:
            return "不支持的解决策略"
        case .resolutionFailed(let detail):
            return "解决失败: \(detail)"
        }
    }
}
