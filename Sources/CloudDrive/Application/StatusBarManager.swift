//
//  StatusBarManager.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  系统状态栏图标与托盘控制台管理 (实时挂载状态、快速挂载/卸载、Finder 直达)
//

import SwiftUI
import AppKit
import Combine
import FileProvider
import CloudDriveCore
import CloudDriveSystem

@MainActor
class StatusBarManager: ObservableObject {
    static let shared = StatusBarManager()
    
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    weak var appState: AppState?
    private var showMenuBarIcon: Bool {
        get { AppSettings.shared.showMenuBarIcon }
        set { AppSettings.shared.showMenuBarIcon = newValue }
    }
    
    private init() {
        setupStatusBar()
    }
    
    func configure(with appState: AppState) {
        self.appState = appState
        updatePopoverContent()
        updateStatusIcon()
    }
    
    func setupStatusBar() {
        guard showMenuBarIcon else {
            removeStatusBar()
            return
        }
        
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = statusItem?.button {
                button.image = NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: "CloudDrive")
                button.imagePosition = .imageOnly
                button.target = self
                button.action = #selector(togglePopover)
            }
        }
        
        if popover == nil {
            popover = NSPopover()
            popover?.behavior = .transient
            popover?.contentSize = NSSize(width: 320, height: 380)
        }
        
        updatePopoverContent()
    }
    
    func removeStatusBar() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        popover = nil
    }
    
    func toggleMenuBarVisibility(_ show: Bool) {
        showMenuBarIcon = show
        if show {
            setupStatusBar()
        } else {
            removeStatusBar()
        }
    }
    
    func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        
        let activeCount = FileProgressPublisher.shared.getActiveTransfers().count
        if activeCount > 0 {
            button.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Syncing")
            return
        }
        
        if let appState = appState {
            let mountedCount = appState.vaults.filter(\.isMounted).count
            if mountedCount > 0 {
                button.image = NSImage(systemSymbolName: "icloud.fill", accessibilityDescription: "CloudDrive")
            } else {
                button.image = NSImage(systemSymbolName: "icloud", accessibilityDescription: "CloudDrive")
            }
        } else {
            button.image = NSImage(systemSymbolName: "icloud", accessibilityDescription: "CloudDrive")
        }
    }
    
    private func updatePopoverContent() {
        guard let popover = popover else { return }
        let contentView = StatusBarPopoverView(statusBarManager: self)
            .environmentObject(LocalizationManager.shared)
        let hostingController = NSHostingController(rootView: contentView)
        popover.contentViewController = hostingController
    }
    
    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            updatePopoverContent()
            updateStatusIcon()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
    
    func closePopover() {
        popover?.performClose(nil)
    }
}

// MARK: - 状态栏弹出控制面板视图

struct StatusBarPopoverView: View {
    @ObservedObject var statusBarManager: StatusBarManager
    @ObservedObject private var localization = LocalizationManager.shared
    @State private var activeTransfers: [ActiveTransferInfo] = FileProgressPublisher.shared.getActiveTransfers()
    
    private var appState: AppState? {
        statusBarManager.appState
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 1. 顶部 Header
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: "icloud.fill")
                        .foregroundColor(.blue)
                        .font(.system(size: 16))
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("app_name"))
                        .font(.headline)
                        .fontWeight(.semibold)
                    
                    if let appState = appState {
                        let total = appState.vaults.count
                        let mounted = appState.vaults.filter(\.isMounted).count
                        Text(L("popover_vaults_count", mounted, total))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                Button {
                    openMainWindow()
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("menu_open_main_window"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // 2. 状态管理面板 (参考 iCloud: 传输中展示实时进度列表，空闲时展示“已全部同步/最新状态”)
            if !activeTransfers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(L("popover_syncing_title"), systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(activeTransfers.count)")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .clipShape(Capsule())
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(activeTransfers) { item in
                                StatusBarTransferRow(transfer: item)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                    }
                    .frame(maxHeight: 140)
                    
                    Divider()
                }
            } else if let appState = appState, appState.vaults.contains(where: \.isMounted) {
                // iCloud 风格：所有文件已同步完成的轻量状态提示
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 13))
                    Text(L("status_all_synced_desc"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
                
                Divider()
            }
            
            // 3. 保险库快速操作列表
            if let appState = appState, !appState.vaults.isEmpty {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(appState.vaults) { vault in
                            StatusBarVaultRow(vault: vault, appState: appState)
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 220)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "externaldrive.badge.plus")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text(L("popover_no_vaults"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 100)
            }
            
            Divider()
            
            // 4. 底部功能按钮组
            VStack(spacing: 4) {
                Button {
                    openMainWindow()
                } label: {
                    Label(L("popover_open_main"), systemImage: "macwindow")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                
                Button {
                    openCloudStorageInFinder()
                } label: {
                    Label(L("popover_open_finder"), systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                
                Button {
                    openPreferences()
                } label: {
                    Label(L("popover_preferences"), systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                
                Divider()
                    .padding(.vertical, 2)
                
                Button(role: .destructive) {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label(L("popover_quit"), systemImage: "power")
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .font(.system(size: 12))
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        }
        .frame(width: 330)
        .onReceive(NotificationCenter.default.publisher(for: FileProgressPublisher.transferDidUpdateNotification)) { _ in
            activeTransfers = FileProgressPublisher.shared.getActiveTransfers()
        }
        .onReceive(NotificationCenter.default.publisher(for: FileProgressPublisher.transferDidCompleteNotification)) { _ in
            activeTransfers = FileProgressPublisher.shared.getActiveTransfers()
        }
        .onAppear {
            activeTransfers = FileProgressPublisher.shared.getActiveTransfers()
        }
    }
    
    private func openMainWindow() {
        statusBarManager.closePopover()
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title.contains("CloudDrive") || $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
    
    private func openCloudStorageInFinder() {
        statusBarManager.closePopover()
        NSWorkspace.shared.open(CloudDrivePaths.cloudStorageDirectory)
    }
    
    private func openPreferences() {
        statusBarManager.closePopover()
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: Notification.Name("OpenSettingsModal"), object: nil)
    }
}

// MARK: - 状态栏保险库行卡片

struct StatusBarVaultRow: View {
    let vault: VaultInfo
    @ObservedObject var appState: AppState
    @ObservedObject private var localization = LocalizationManager.shared
    
    @State private var isProcessing = false
    
    var body: some View {
        HStack(spacing: 8) {
            // 优雅的 iCloud 风格挂载图标
            Image(systemName: vault.isMounted ? "icloud.fill" : "icloud")
                .font(.system(size: 14))
                .foregroundColor(vault.isMounted ? .blue : .secondary.opacity(0.6))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(vault.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                
                HStack(spacing: 4) {
                    Text(vault.storageType.localizedName)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    
                    Text("•")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary.opacity(0.5))
                    
                    Text(vault.isMounted ? L("vault_status_mounted") : L("vault_status_unmounted"))
                        .font(.system(size: 9))
                        .foregroundColor(vault.isMounted ? .green : .secondary)
                    
                    if vault.isMounted {
                        let cacheMB = CacheManager.forVault(vault.id).currentCacheSize() / (1024 * 1024)
                        let maxGB = CacheManager.forVault(vault.id).maxCacheSize / (1024 * 1024 * 1024)
                        Text("•")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("缓存 \(cacheMB)M/\(maxGB)G")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
            
            if isProcessing {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 14, height: 14)
            } else {
                if vault.isMounted {
                    // Finder 按钮
                    Button {
                        openInFinder(vault: vault)
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("vault_card_open_in_finder"))
                    
                    // 卸载按钮
                    Button {
                        isProcessing = true
                        appState.unmountVault(vault)
                        isProcessing = false
                    } label: {
                        Image(systemName: "eject.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("popover_quick_unmount"))
                } else {
                    // 挂载按钮
                    Button {
                        doMount()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 8))
                            Text(L("vault_card_mount"))
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundColor(.accentColor)
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(6)
    }
    
    private func doMount() {
        if vault.isEncrypted && appState.getVaultPassword(for: vault.id) == nil {
            appState.selectedVaultForUnlock = vault
            appState.showUnlockVault = true
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        isProcessing = true
        Task {
            do {
                try await appState.remountVault(vault)
            } catch {
                let nsError = error as NSError
                if vault.isEncrypted && (nsError.localizedDescription.contains("无法获取保险库加密密码") ||
                                         nsError.localizedDescription.contains("Unable to obtain vault encryption password") ||
                                         nsError.localizedDescription == L("err_cannot_get_password")) {
                    await MainActor.run {
                        appState.selectedVaultForUnlock = vault
                        appState.showUnlockVault = true
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            }
            await MainActor.run {
                isProcessing = false
            }
        }
    }
    
    private func openInFinder(vault: VaultInfo) {
        if let manager = FileProviderDomainService.shared.getManager(for: vault) {
            manager.getUserVisibleURL(for: NSFileProviderItemIdentifier.rootContainer) { url, _ in
                DispatchQueue.main.async {
                    if let url = url {
                        NSWorkspace.shared.open(url)
                    } else {
                        let cloudStorageURL = CloudDrivePaths.cloudStorageDirectory
                        let candidate = cloudStorageURL.appendingPathComponent("CloudDrive-\(vault.name)")
                        if FileManager.default.fileExists(atPath: candidate.path) {
                            NSWorkspace.shared.open(candidate)
                        } else {
                            NSWorkspace.shared.open(cloudStorageURL)
                        }
                    }
                }
            }
        } else {
            let cloudStorageURL = CloudDrivePaths.cloudStorageDirectory
            let candidate = cloudStorageURL.appendingPathComponent("CloudDrive-\(vault.name)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                NSWorkspace.shared.open(candidate)
            } else {
                NSWorkspace.shared.open(cloudStorageURL)
            }
        }
    }
}

// MARK: - 状态栏传输任务行卡片

struct StatusBarTransferRow: View {
    let transfer: ActiveTransferInfo
    @ObservedObject private var localization = LocalizationManager.shared
    
    private var speedText: String {
        if transfer.isPaused {
            return L("transfer_paused")
        }
        guard transfer.speedBytesPerSec > 0 else { return "-- KB/s" }
        return ByteCountFormatter.string(fromByteCount: transfer.speedBytesPerSec, countStyle: .file) + "/s"
    }
    
    private var progressText: String {
        let completed = ByteCountFormatter.string(fromByteCount: transfer.completedBytes, countStyle: .file)
        if transfer.totalBytes > 0 {
            let total = ByteCountFormatter.string(fromByteCount: transfer.totalBytes, countStyle: .file)
            return "\(completed) / \(total)"
        } else {
            return completed
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: transfer.kind == .downloading ? "icloud.and.arrow.down.fill" : "icloud.and.arrow.up.fill")
                    .foregroundColor(transfer.kind == .downloading ? .indigo : .blue)
                    .font(.system(size: 13))
                
                Text(transfer.fileName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Spacer()
                
                Text(speedText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            
            ProgressView(value: transfer.progressFraction)
                .progressViewStyle(.linear)
            
            HStack {
                Text(progressText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                
                Spacer()
                
                Text("\(Int(transfer.progressFraction * 100))%")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(6)
    }
}

extension StorageType {
    var themeColor: Color {
        switch self {
        case .webdav: return .teal
        case .s3: return .orange
        case .baidupan: return .blue
        case .smb: return .purple
        case .ftp: return .yellow
        case .pan123: return .cyan
        case .local: return .green
        }
    }
}