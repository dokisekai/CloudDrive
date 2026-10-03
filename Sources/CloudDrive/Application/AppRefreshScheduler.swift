import Foundation
import Network
import CloudDriveCore

/// Owns timer and network-monitor lifetime. Mount state and UI updates stay with AppState.
@MainActor
final class AppRefreshScheduler {
    private var autoRefreshTimer: Timer?
    private var refreshTickCounter = 0
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "net.aabg.CloudDrive.networkMonitor")

    func start(mountedVaults: @escaping () -> [VaultInfo], refreshVault: @escaping (String) async -> Void, refreshAll: @escaping () async -> Void) {
        stop()
        
        // 1. 每 30 秒自动巡检已挂载保险库的同步队列；仅当队列有待处理任务或定时周期（60s）到达时刷新 FileProvider
        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.refreshTickCounter += 1
                var queueHadItems = false
                
                for vault in mountedVaults() {
                    let manager = SyncManager.forVault(vault.id)
                    if manager.getSyncQueueCount() > 0 {
                        manager.processSyncQueue()
                        queueHadItems = true
                        await refreshVault(vault.id)
                    }
                }
                
                // 每 60 秒（2次 tick）低频同步远端外部变更，避免空闲时产生网络轮询风暴
                if self.refreshTickCounter % 2 == 0 && !queueHadItems {
                    await refreshAll()
                }
            }
        }
        
        // 2. 监听网络连接状态：一旦网络重连/恢复，立即触发离线上传队列并全量刷新
        networkMonitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied {
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    NSLog("🌐 AppState: Network restored online, triggering offline sync queue and refreshing cloud data...")
                    for vault in mountedVaults() {
                        SyncManager.forVault(vault.id).processSyncQueue()
                    }
                    await refreshAll()
                }
            }
        }
        networkMonitor.start(queue: networkQueue)
        
        NSLog("🔄 AppState: Auto-refresh engine and network monitor started (poll interval: 30s)")
    }

    func stop() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
        networkMonitor.cancel()
    }

}
