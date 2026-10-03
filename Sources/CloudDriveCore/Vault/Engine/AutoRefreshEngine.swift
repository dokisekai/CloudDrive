//
//  AutoRefreshEngine.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  后台自动差量刷新与网络连接恢复调度引擎
//

import Foundation

public final class AutoRefreshEngine: @unchecked Sendable {
    public static let shared = AutoRefreshEngine()
    
    private var timer: Timer?
    private var refreshAction: (@Sendable () async -> Void)?
    private let lock = NSLock()
    private var isRunning = false
    
    private init() {}
    
    /// 启动自动刷新调度引擎
    public func start(
        interval: TimeInterval = 10.0,
        onRefresh: @escaping @Sendable () async -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        
        stopInternal()
        
        self.refreshAction = onRefresh
        self.isRunning = true
        
        // 1. 周期性轮询调度
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                guard let self = self, self.isRunning else { return }
                Task {
                    await self.refreshAction?()
                }
            }
        }
        
        // 2. 监听网络连接变化
        NetworkMonitorService.shared.onStatusChanged { [weak self] status in
            guard let self = self, status == .online, self.isRunning else { return }
            Logger.shared.info(.system, "AutoRefreshEngine: Network restored online, triggering offline sync & refresh...")
            SyncService.shared.processSyncQueue()
            Task {
                await self.refreshAction?()
            }
        }
        
        Logger.shared.info(.system, "AutoRefreshEngine started (interval: \(interval)s)")
    }
    
    /// 停止自动刷新调度引擎
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopInternal()
    }
    
    private func stopInternal() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        refreshAction = nil
        Logger.shared.info(.system, "AutoRefreshEngine stopped")
    }
}
