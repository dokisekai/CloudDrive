//
//  FileProgressPublisher.swift
//  CloudDriveSystem
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  macOS Finder 原生进度发布器与全局传输追踪器 (NSProgress.publish 桥接)
//

import Foundation
import FileProvider
import CloudDriveContracts
import CloudDriveSupport
import CloudDriveSecurity

/// 传输任务信息结构体
public struct ActiveTransferInfo: Sendable, Identifiable {
    public let id: String // fileId
    public let vaultId: String?
    public let fileName: String
    public let totalBytes: Int64
    public var completedBytes: Int64
    public var speedBytesPerSec: Int64
    public let kind: Progress.FileOperationKind
    public var isPaused: Bool
    public var startedAt: Date
    public var lastUpdatedAt: Date
    
    public var progressFraction: Double {
        guard totalBytes > 0 else { return 0.0 }
        return min(max(Double(completedBytes) / Double(totalBytes), 0.0), 1.0)
    }
}

/// 管理在 macOS Finder 中发布和注销文件原生进度的单例
public final class FileProgressPublisher: @unchecked Sendable {
    public static let shared = FileProgressPublisher()
    
    public static let transferDidUpdateNotification = Notification.Name("com.clouddrive.transfer.didUpdate")
    public static let transferDidCompleteNotification = Notification.Name("com.clouddrive.transfer.didComplete")
    public static let transferUserDidCancelNotification = Notification.Name("com.clouddrive.transfer.userDidCancel")
    
    private struct TransferState {
        let progress: Progress
        var info: ActiveTransferInfo
        var lastBytes: Int64
        var lastTime: Date
        var lastNotifiedTime: Date
    }
    
    private var transfers: [String: TransferState] = [:]
    private let lock = NSLock()
    
    private init() {}
    
    /// 开始发布一个文件的原生传输进度
    @discardableResult
    public func startProgress(
        fileId: String,
        fileName: String,
        relativePath: String? = nil,
        vaultId: String? = nil,
        userVisibleURL: URL? = nil,
        totalBytes: Int64,
        kind: Progress.FileOperationKind
    ) -> Progress {
        lock.lock()
        defer { lock.unlock() }
        
        // 如果已存在旧的进度，先注销
        if let existing = transfers.removeValue(forKey: fileId) {
            existing.progress.unpublish()
        }
        
        let unitCount = totalBytes > 0 ? totalBytes : 100
        let progress = Progress(totalUnitCount: unitCount)
        progress.kind = .file
        progress.fileOperationKind = kind
        progress.isPausable = true
        progress.isCancellable = true
        
        // 尝试解析用户在 ~/Library/CloudStorage 中的可见文件路径及挂载根目录
        let (effectiveURL, mountRootURL) = resolveEffectiveURLs(
            relativePath: relativePath ?? fileName,
            vaultId: vaultId,
            userVisibleURL: userVisibleURL
        )
        if let effectiveURL = effectiveURL {
            progress.fileURL = effectiveURL
            progress.setUserInfoObject(effectiveURL, forKey: .fileURLKey)
        }
        progress.setUserInfoObject(kind, forKey: .fileOperationKindKey)
        progress.setUserInfoObject(NSNumber(value: 1), forKey: .fileTotalCountKey)
        progress.setUserInfoObject(NSNumber(value: 0), forKey: .fileCompletedCountKey)
        
        // 挂载 Finder 原生取消和暂停/恢复事件处理
        progress.cancellationHandler = { [weak self] in
            self?.handleCancellation(fileId: fileId)
        }
        progress.pausingHandler = { [weak self] in
            self?.pauseProgress(fileId: fileId)
        }
        progress.resumingHandler = { [weak self] in
            self?.resumeProgress(fileId: fileId)
        }
        
        // 关键调用：向 macOS 系统广播，Finder 会自动在其文件图标旁渲染动态饼图进度圈并在状态栏显示进度
        progress.publish()
        
        // 联动文件夹层级进度聚合器 (iCloud 体验)
        if let effectiveURL = effectiveURL, let mountRootURL = mountRootURL {
            FolderProgressAggregator.shared.fileDidStart(
                fileId: fileId,
                fileURL: effectiveURL,
                mountRootURL: mountRootURL,
                totalBytes: totalBytes,
                kind: kind
            )
        }
        
        let now = Date()
        let info = ActiveTransferInfo(
            id: fileId,
            vaultId: vaultId,
            fileName: fileName,
            totalBytes: totalBytes,
            completedBytes: 0,
            speedBytesPerSec: 0,
            kind: kind,
            isPaused: false,
            startedAt: now,
            lastUpdatedAt: now
        )
        
        transfers[fileId] = TransferState(
            progress: progress,
            info: info,
            lastBytes: 0,
            lastTime: now,
            lastNotifiedTime: now
        )
        
        postUpdateNotification()
        return progress
    }
    
    /// 更新已传输字节数并计算瞬时速率及预估剩余时间
    public func updateProgress(fileId: String, completedBytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        
        guard var state = transfers[fileId] else { return }
        
        let unitCount = state.info.totalBytes > 0 ? completedBytes : min(completedBytes, 100)
        state.progress.completedUnitCount = unitCount
        state.info.completedBytes = completedBytes
        
        let now = Date()
        let timeDelta = now.timeIntervalSince(state.lastTime)
        
        // 至少经过 0.2 秒计算一次速度
        if timeDelta >= 0.2 {
            let bytesDelta = completedBytes - state.lastBytes
            if bytesDelta >= 0 {
                let instantSpeed = Int64(Double(bytesDelta) / timeDelta)
                // 指数移动平均 (EMA) 平滑速度
                let smoothed = state.info.speedBytesPerSec > 0
                    ? Int64(Double(state.info.speedBytesPerSec) * 0.7 + Double(instantSpeed) * 0.3)
                    : instantSpeed
                state.info.speedBytesPerSec = max(smoothed, 0)
            }
            state.lastBytes = completedBytes
            state.lastTime = now
            
            // 注入 Apple 官方 UserInfo 吞吐率和剩余时间预估 (iCloud 体验)
            if state.info.speedBytesPerSec > 0 {
                state.progress.setUserInfoObject(NSNumber(value: state.info.speedBytesPerSec), forKey: .throughputKey)
                if state.info.totalBytes > completedBytes {
                    let remaining = state.info.totalBytes - completedBytes
                    let eta = Double(remaining) / Double(state.info.speedBytesPerSec)
                    state.progress.setUserInfoObject(NSNumber(value: eta), forKey: .estimatedTimeRemainingKey)
                }
            }
        }
        
        state.info.lastUpdatedAt = now
        transfers[fileId] = state
        
        // 联动文件夹层级进度聚合器
        FolderProgressAggregator.shared.fileDidUpdate(
            fileId: fileId,
            completedBytes: completedBytes,
            speedBytesPerSec: state.info.speedBytesPerSec
        )
        
        // 节流通知 (约 150ms 触发一次)，避免过密打满主线程
        if now.timeIntervalSince(state.lastNotifiedTime) >= 0.15 {
            state.lastNotifiedTime = now
            transfers[fileId] = state
            postUpdateNotification()
        }
    }
    
    /// 暂停进度
    public func pauseProgress(fileId: String) {
        lock.lock()
        defer { lock.unlock() }
        if var state = transfers[fileId] {
            state.progress.pause()
            state.info.isPaused = true
            state.info.speedBytesPerSec = 0
            transfers[fileId] = state
            postUpdateNotification()
        }
    }
    
    /// 恢复进度
    public func resumeProgress(fileId: String) {
        lock.lock()
        defer { lock.unlock() }
        if var state = transfers[fileId] {
            state.progress.resume()
            state.info.isPaused = false
            state.lastTime = Date()
            transfers[fileId] = state
            postUpdateNotification()
        }
    }
    
    /// 完成或取消传输，注销系统原生进度
    public func finishProgress(fileId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        // 联动文件夹层级进度聚合器
        FolderProgressAggregator.shared.fileDidFinish(fileId: fileId)
        
        if let state = transfers.removeValue(forKey: fileId) {
            state.progress.completedUnitCount = state.progress.totalUnitCount
            state.progress.unpublish()
        }
        
        postCompleteNotification(fileId: fileId)
    }
    
    /// 取消指定 Vault 或全局的所有活跃传输并注销所有进度 (用于保险库锁定 / 卸载生命周期)
    public func cancelTransfers(for vaultId: String? = nil) {
        lock.lock()
        let targets: [String]
        if let vid = vaultId {
            targets = transfers.filter { $0.value.info.vaultId == vid }.map(\.key)
        } else {
            targets = Array(transfers.keys)
        }
        lock.unlock()
        
        for fileId in targets {
            finishProgress(fileId: fileId)
        }
    }
    
    /// 获取当前所有正在进行的传输快照
    public func getActiveTransfers() -> [ActiveTransferInfo] {
        lock.lock()
        defer { lock.unlock() }
        return transfers.values.map(\.info).sorted { $0.startedAt < $1.startedAt }
    }
    
    // MARK: - Private Action Handlers
    
    private func handleCancellation(fileId: String) {
        lock.lock()
        let vaultId = transfers[fileId]?.info.vaultId
        lock.unlock()
        
        finishProgress(fileId: fileId)
        
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: FileProgressPublisher.transferUserDidCancelNotification,
                object: nil,
                userInfo: ["fileId": fileId, "vaultId": vaultId as Any]
            )
        }
    }
    
    // MARK: - Path Resolution Helpers
    
    /// 解析相对路径或直接指定 URL 对应的有效用户可见 URL 和挂载根目录
    public func resolveEffectiveURLs(
        relativePath: String,
        vaultId: String?,
        userVisibleURL: URL?
    ) -> (fileURL: URL?, mountRootURL: URL?) {
        if let userVisibleURL = userVisibleURL {
            let mount = resolveMountRootFromUserVisibleURL(userVisibleURL, relativePath: relativePath) ?? resolveMountRootURL(vaultId: vaultId)
            return (userVisibleURL, mount)
        }
        
        if let mountRoot = resolveMountRootURL(vaultId: vaultId) {
            let fileURL = mountRoot.appendingPathComponent(relativePath)
            return (fileURL, mountRoot)
        }
        
        return (nil, nil)
    }
    
    /// 向后兼容的解析方法
    public func resolveUserVisibleURL(fileName: String, vaultId: String?) -> URL? {
        return resolveEffectiveURLs(relativePath: fileName, vaultId: vaultId, userVisibleURL: nil).fileURL
    }
    
    /// 解析保险库在 ~/Library/CloudStorage 中的真实挂载根目录
    public func resolveMountRootURL(vaultId: String?) -> URL? {
        let cloudStorage = CloudDrivePaths.cloudStorageDirectory
        
        // 1. 如果有特定 vaultId，尝试读取 VaultRegistry 得到 displayName
        if let vaultId = vaultId, !vaultId.isEmpty {
            if let vault = VaultRegistry.shared.loadVaultConfig(for: vaultId) {
                let namedDir = cloudStorage.appendingPathComponent("CloudDrive-\(vault.name)")
                if FileManager.default.fileExists(atPath: namedDir.path) {
                    return namedDir
                }
            }
            
            let direct = cloudStorage.appendingPathComponent("CloudDrive-\(vaultId)")
            if FileManager.default.fileExists(atPath: direct.path) {
                return direct
            }
            
            // 尝试去除 "vault_" 前缀及可能带有的末尾短哈希
            var cleanName = vaultId
            if cleanName.hasPrefix("vault_") {
                cleanName = String(cleanName.dropFirst(6))
            }
            if let lastUnderscore = cleanName.lastIndex(of: "_") {
                let candidateName = String(cleanName[..<lastUnderscore])
                let dir = cloudStorage.appendingPathComponent("CloudDrive-\(candidateName)")
                if FileManager.default.fileExists(atPath: dir.path) {
                    return dir
                }
            }
            let strippedDir = cloudStorage.appendingPathComponent("CloudDrive-\(cleanName)")
            if FileManager.default.fileExists(atPath: strippedDir.path) {
                return strippedDir
            }
        }
        
        // 2. 检查 ~/Library/CloudStorage 下所有 CloudDrive* 挂载目录
        if let contents = try? FileManager.default.contentsOfDirectory(at: cloudStorage, includingPropertiesForKeys: nil) {
            let cloudDirs = contents.filter { $0.lastPathComponent.hasPrefix("CloudDrive") }
            
            // 如果传入了 vaultId，看哪个目录名称包含 vaultId 的核心字段
            if let vaultId = vaultId, !vaultId.isEmpty {
                let key = vaultId.replacingOccurrences(of: "vault_", with: "")
                for dir in cloudDirs {
                    let dirName = dir.lastPathComponent
                    if dirName.contains(key) || key.contains(dirName.replacingOccurrences(of: "CloudDrive-", with: "")) {
                        return dir
                    }
                }
            }
            
            // 如果仅有一个 CloudDrive 挂载目录，则直接使用它
            if cloudDirs.count == 1, let single = cloudDirs.first {
                return single
            }
        }
        
        // 3. 尝试探测默认挂载点
        let defaultDir = cloudStorage.appendingPathComponent("CloudDrive")
        if FileManager.default.fileExists(atPath: defaultDir.path) {
            return defaultDir
        }
        
        // 4. 若物理目录尚未刷出，但有明确的 vaultId，构建标准挂载路径
        if let vaultId = vaultId, !vaultId.isEmpty {
            if let vault = VaultRegistry.shared.loadVaultConfig(for: vaultId) {
                return cloudStorage.appendingPathComponent("CloudDrive-\(vault.name)")
            }
            return cloudStorage.appendingPathComponent("CloudDrive-\(vaultId)")
        }
        
        return nil
    }
    
    private func resolveMountRootFromUserVisibleURL(_ url: URL, relativePath: String) -> URL? {
        let cleanRel = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !cleanRel.isEmpty {
            let relComponents = cleanRel.split(separator: "/")
            var current = url
            for _ in 0..<relComponents.count {
                current = current.deletingLastPathComponent()
            }
            if current.path != "/" && current.path != url.path {
                return current
            }
        }
        
        let cloudStoragePath = CloudDrivePaths.cloudStorageDirectory.standardizedFileURL.path.precomposedStringWithCanonicalMapping
        var current = url.deletingLastPathComponent().standardizedFileURL
        while current.path != "/" {
            if current.deletingLastPathComponent().standardizedFileURL.path.precomposedStringWithCanonicalMapping == cloudStoragePath {
                return current
            }
            current = current.deletingLastPathComponent().standardizedFileURL
        }
        return nil
    }
    
    private func postUpdateNotification() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: FileProgressPublisher.transferDidUpdateNotification, object: nil)
        }
    }
    
    private func postCompleteNotification(fileId: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: FileProgressPublisher.transferDidCompleteNotification,
                object: nil,
                userInfo: ["fileId": fileId]
            )
        }
    }
}
