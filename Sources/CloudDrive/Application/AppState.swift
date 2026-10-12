//
//  AppState.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  应用状态管理
//

import SwiftUI
import CloudDriveCore
import CloudDriveSystem
import FileProvider
import Network
import AppKit
@preconcurrency import UserNotifications

/// 应用状态
@MainActor
class AppState: ObservableObject {
    @Published var vaults: [VaultInfo] = []
    @Published var isVaultUnlocked = false
    @Published var currentVault: VaultInfo?
    
    @Published var showCreateVault = false
    @Published var showUnlockVault = false
    @Published var selectedVaultForUnlock: VaultInfo?
    
    let vfs = VirtualFileSystem.shared
    let userDefaults = UserDefaults.standard
    let vaultsKey = "savedVaults"
    
    let refreshScheduler = AppRefreshScheduler()
    
    private var lastActivityTime: Date = Date()
    private var localEventMonitor: Any?
    private var autoLockTimer: Timer?

    init() {
        NSLog("🚀 AppState: Initializing...")
        loadVaults()
        BaiduPanTokenStore().broadcastExistingTokens()
        refreshMountedDomains()
        startAutoRefreshEngine()
        setupAutoLockEngine()
        NotificationCenter.default.addObserver(
            forName: .vaultDidLock,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshMountedDomains()
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("net.aabg.CloudDrive.requestUnlock"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let vaultId = note.userInfo?["vaultId"] as? String
            Task { @MainActor [weak self] in
                self?.handleRequestUnlock(vaultId: vaultId)
            }
        }

        autoMountEligibleVaults()
        NSLog("✅ AppState: Initialization complete")
    }
    
    // MARK: - 自动挂载所有符合条件的存储库（开机 / 启动 / 守护重启）
    public func autoMountEligibleVaults() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            guard AppSettings.shared.autoMountOnLaunch else {
                NSLog("ℹ️ AppState: Auto-mount on launch is disabled in AppSettings")
                return
            }
            for vault in self.vaults {
                if vault.isAutoMount && vault.isStorageEnabled {
                    if vault.isMounted && (!vault.isEncrypted || vault.isUnlocked) {
                        try? await self.registerFileProviderDomain(for: vault)
                        continue
                    }
                    NSLog("📂 AppState: Auto-mounting eligible vault: \(vault.name)")
                    do {
                        try await self.remountVault(vault)
                        NSLog("✅ AppState: Auto-mounted vault successfully: \(vault.name)")
                    } catch {
                        NSLog("⚠️ AppState: Auto-mount failed for vault \(vault.name): \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    
    // MARK: - 响应 Finder 侧边栏访问受保护库的解锁请求
    func handleRequestUnlock(vaultId: String?) {
        guard let vaultId = vaultId,
              let vault = vaults.first(where: { $0.id == vaultId }),
              vault.isEncrypted,
              !vault.isUnlocked else { return }
        
        NSLog("🔓 AppState: Received requestUnlock notification for vault: \(vault.name)")
        self.selectedVaultForUnlock = vault
        self.showUnlockVault = true
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // MARK: - 自动锁定引擎 (依据 AppSettings.shared.autoLock & autoLockTimeout)
    
    private func setupAutoLockEngine() {
        lastActivityTime = Date()
        
        // 监听本地用户操作（按键、点击、滚轮）以刷新活跃时间
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            self?.lastActivityTime = Date()
            return event
        }
        
        // 监听系统休眠 / 锁屏通知
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, AppSettings.shared.autoLock else { return }
            NSLog("🔒 AppState: System will sleep, locking active vault...")
            Task { @MainActor in
                self.lockVault()
            }
        }
        
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, AppSettings.shared.autoLock else { return }
            NSLog("🔒 AppState: Screen did sleep, locking active vault...")
            Task { @MainActor in
                self.lockVault()
            }
        }
        
        // 启动后台定时器，周期性检测闲置超时 (每 30 秒轮询一次)
        autoLockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                guard AppSettings.shared.autoLock, self.isVaultUnlocked else { return }
                let idleSeconds = Date().timeIntervalSince(self.lastActivityTime)
                let timeoutSeconds = AppSettings.shared.autoLockTimeout * 60
                if idleSeconds >= timeoutSeconds {
                    NSLog("🔒 AppState: Auto-locking vault due to inactivity (\(Int(idleSeconds))s >= \(Int(timeoutSeconds))s)")
                    self.lockVault()
                }
            }
        }
    }
    
    // MARK: - 系统级挂载 / 卸载通知 (依据 AppSettings.shared.showNotifications)
    
    public func postSystemNotification(title: String, subtitle: String = "", body: String) {
        guard AppSettings.shared.showNotifications else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted {
                        Task { @MainActor in
                            self.deliverNotification(title: title, subtitle: subtitle, body: body)
                        }
                    }
                }
            } else if settings.authorizationStatus == .authorized {
                Task { @MainActor in
                    self.deliverNotification(title: title, subtitle: subtitle, body: body)
                }
            }
        }
    }
    
    private func deliverNotification(title: String, subtitle: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        if !subtitle.isEmpty {
            content.subtitle = subtitle
        }
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
