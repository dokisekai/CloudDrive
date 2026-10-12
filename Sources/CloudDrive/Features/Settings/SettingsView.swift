//
//  SettingsView.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  偏好设置中心 - 现代 macOS 侧边栏分栏架构 (通用、存储缓存、忽略规则、日志监控、产品关于)
//

import SwiftUI
import AppKit
import CloudDriveCore
import CloudDriveSupport
import CloudDriveCache

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "general"
    case cache = "cache"
    case ignore = "ignore"
    case logs = "logs"
    case about = "about"
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .general: return L("tab_general")
        case .cache: return L("tab_cache")
        case .ignore: return L("tab_ignore_rules")
        case .logs: return L("tab_logs")
        case .about: return L("tab_about")
        }
    }
    
    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .cache: return "internaldrive.fill"
        case .ignore: return "eye.slash.fill"
        case .logs: return "doc.text.fill"
        case .about: return "info.circle.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .general: return .blue
        case .cache: return .purple
        case .ignore: return .orange
        case .logs: return .green
        case .about: return .cyan
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var localization = LocalizationManager.shared
    @State private var selectedTab: SettingsTab = .general
    
    var body: some View {
        HStack(spacing: 0) {
            // 左侧分栏导航
            VStack(spacing: 6) {
                // 侧边栏标题栏
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.secondary)
                    Text(L("settings_title"))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 6)
                
                ForEach(SettingsTab.allCases) { tab in
                    SettingsSidebarRow(
                        tab: tab,
                        isSelected: selectedTab == tab,
                        action: { selectedTab = tab }
                    )
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
            .frame(width: 190)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // 右侧内容详情
            VStack(spacing: 0) {
                // 顶栏：标题与完成按钮
                HStack {
                    Text(selectedTab.title)
                        .font(.title3)
                        .fontWeight(.semibold)
                    
                    Spacer()
                    
                    Button(L("done")) {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 12)
                .background(Color(NSColor.windowBackgroundColor))
                
                Divider()
                
                // 详情区域
                Group {
                    switch selectedTab {
                    case .general:
                        GeneralSettingsView()
                    case .cache:
                        CacheSettingsView()
                    case .ignore:
                        IgnoreSettingsView()
                    case .logs:
                        LogManagementView(showsHeader: false)
                    case .about:
                        AboutView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 720, idealWidth: 760, minHeight: 500, idealHeight: 540)
    }
}

struct SettingsSidebarRow: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(tab.color)
                        .frame(width: 24, height: 24)
                    Image(systemName: tab.icon)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                }
                
                Text(tab.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .white : .primary)
                
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor : (isHovered ? Color.secondary.opacity(0.08) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct GeneralSettingsView: View {
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var settings = AppSettings.shared
    
    var body: some View {
        Form {
            // MARK: 界面语言
            Section {
                HStack {
                    Text(L("settings_language"))
                        .font(.body)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { localization.selectedLanguage },
                        set: { localization.setLanguage($0) }
                    )) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 180)
                }
            } header: {
                Text(L("settings_language"))
            } footer: {
                Text(L("settings_language_desc"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            // MARK: 菜单栏
            Section {
                Toggle(L("settings_menubar_toggle"), isOn: $settings.showMenuBarIcon)
                    .onChange(of: settings.showMenuBarIcon) { newValue in
                        StatusBarManager.shared.toggleMenuBarVisibility(newValue)
                    }
            } header: {
                Text(L("menu_bar_settings_header"))
            } footer: {
                Text(L("settings_menubar_toggle_desc"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            // MARK: 启动行为
            Section {
                Toggle(L("settings_show_main_on_launch"), isOn: $settings.showMainWindowOnLaunch)
                Toggle(L("settings_auto_mount_on_launch"), isOn: $settings.autoMountOnLaunch)
                Toggle(L("settings_confirm_before_unmount"), isOn: $settings.confirmBeforeUnmount)
                Toggle(L("settings_show_notifications"), isOn: $settings.showNotifications)
            } header: {
                Text(L("settings_startup_behavior"))
            } footer: {
                Text(L("settings_startup_behavior_desc"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            // MARK: 安全
            Section {
                Toggle(L("settings_auto_lock"), isOn: $settings.autoLock)
                
                if settings.autoLock {
                    HStack {
                        Text(L("settings_lock_timeout"))
                        Spacer()
                        Slider(value: $settings.autoLockTimeout, in: 5...60, step: 5)
                            .frame(width: 140)
                        Text(L("settings_lock_timeout_minutes", Int(settings.autoLockTimeout)))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                            .frame(width: 65, alignment: .trailing)
                    }
                }
            } header: {
                Text(L("settings_security"))
            } footer: {
                Text(L("settings_auto_lock_desc"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(16)
    }
}

struct CacheSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedVaultId: String = "all"
    
    @State private var diskSpaceInfo: DiskSpaceInfo? = nil
    @State private var dynamicCacheSize: String? = nil
    @State private var pinnedCacheSize: String? = nil
    @State private var pinnedCount: Int = 0
    @State private var thumbnailCacheSize: String? = nil
    
    @State private var isClearing = false
    @State private var showClearedAlert = false
    
    var body: some View {
        Form {
            // MARK: - 存储与使用概览 (Storage & Usage Breakdown)
            Section {
                if !appState.vaults.isEmpty {
                    HStack {
                        Text(L("cache_filter_vault"))
                        Spacer()
                        Picker("", selection: $selectedVaultId) {
                            Text(L("sidebar_all_vaults")).tag("all")
                            ForEach(appState.vaults) { vault in
                                Text(vault.name).tag(vault.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 170)
                        .onChange(of: selectedVaultId) { _ in
                            updateAll()
                        }
                    }
                }
                
                // Mac 本地磁盘可用空间
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "internaldrive")
                            .foregroundColor(.blue)
                        Text(L("cache_mac_disk_space"))
                    }
                    Spacer()
                    if let disk = diskSpaceInfo {
                        Text(disk.summary)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.primary)
                    } else {
                        Text(L("settings_calculating"))
                            .foregroundColor(.secondary)
                    }
                }
                
                // 动态临时缓存 (按需在线读取产生，受配额/智能模式淘汰管理)
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.horizontal.circle")
                            .foregroundColor(.orange)
                        Text(L("cache_dynamic_size"))
                    }
                    Spacer()
                    Text(dynamicCacheSize ?? L("settings_calculating"))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                
                // 始终保留在此 Mac (用户明确下载/保留，完全独立占用，绝不淘汰)
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "pin.circle.fill")
                            .foregroundColor(.green)
                        Text(L("cache_pinned_size"))
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Text(pinnedCacheSize ?? L("settings_calculating"))
                            .font(.system(.body, design: .monospaced))
                        Text("(\(L("cache_pinned_items_unit", pinnedCount)))")
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text(L("settings_cache_storage"))
            } footer: {
                Text(L("cache_storage_breakdown_desc"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            // MARK: - 缓存管理策略 (Cache Management Strategy)
            Section {
                HStack {
                    Text(L("cache_mode_title"))
                    Spacer()
                    Picker("", selection: $settings.cacheManagementMode) {
                        Text(L("cache_mode_smart")).tag(CacheManagementMode.smart)
                        Text(L("cache_mode_fixed")).tag(CacheManagementMode.fixed)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 250)
                    .onChange(of: settings.cacheManagementMode) { _ in
                        triggerEvictionAndRefresh()
                    }
                }
                
                if settings.cacheManagementMode == .smart {
                    HStack {
                        Text(L("cache_smart_headroom_title"))
                        Spacer()
                        Picker("", selection: $settings.smartFreeSpacePercentage) {
                            Text("10%").tag(10)
                            Text(L("cache_smart_percentage_recommended", 15)).tag(15)
                            Text("20%").tag(20)
                            Text("25%").tag(25)
                            Text("30%").tag(30)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 170)
                        .onChange(of: settings.smartFreeSpacePercentage) { _ in
                            triggerEvictionAndRefresh()
                        }
                    }
                } else {
                    HStack {
                        Text(L("cache_quota_title"))
                        Spacer()
                        Picker("", selection: $settings.maxCacheQuotaGB) {
                            Text("2 GB").tag(2)
                            Text("5 GB").tag(5)
                            Text(L("cache_quota_default", 10)).tag(10)
                            Text("20 GB").tag(20)
                            Text("50 GB").tag(50)
                            Text("100 GB").tag(100)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 170)
                        .onChange(of: settings.maxCacheQuotaGB) { newValue in
                            let quotaBytes = Int64(newValue) * 1024 * 1024 * 1024
                            VirtualFileSystem.shared.cacheManager.maxCacheSize = quotaBytes
                            if selectedVaultId != "all" {
                                CacheManager.forVault(selectedVaultId).maxCacheSize = quotaBytes
                            }
                            triggerEvictionAndRefresh()
                        }
                    }
                }
            } header: {
                Text(L("cache_mode_title"))
            } footer: {
                Text(settings.cacheManagementMode == .smart ? L("cache_smart_headroom_desc") : L("cache_fixed_quota_desc"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            // MARK: - 清理临时缓存
            Section {
                HStack {
                    Text(L("cache_clear_dynamic_only"))
                    Spacer()
                    Button {
                        clearCache()
                    } label: {
                        if isClearing {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                        } else {
                            Text(L("settings_btn_clear_now"))
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isClearing)
                }
            } footer: {
                Text(L("cache_clear_dynamic_only_desc"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            // MARK: - 缩略图缓存
            Section {
                HStack {
                    Text(L("cache_thumbnail_size"))
                    Spacer()
                    Text(thumbnailCacheSize ?? L("settings_calculating"))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text(L("cache_thumbnail_clear_title"))
                    Spacer()
                    Button {
                        clearThumbnailCache()
                    } label: {
                        Text(L("cache_thumbnail_clear_btn"))
                    }
                    .buttonStyle(.bordered)
                }
            } header: {
                Text(L("cache_thumbnail_section"))
            } footer: {
                Text(L("cache_thumbnail_clear_desc"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            // MARK: - 固定保留文件管理
            Section {
                HStack {
                    Text(L("cache_pinned_count"))
                    Spacer()
                    Text(L("cache_pinned_items_unit", pinnedCount))
                        .foregroundColor(.secondary)
                }
                
                if pinnedCount > 0 {
                    HStack {
                        Text(L("cache_pinned_unpin_all_title"))
                        Spacer()
                        Button(L("cache_pinned_unpin_all_btn")) {
                            unpinAll()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } header: {
                Text(L("cache_pinned_section"))
            } footer: {
                if pinnedCount > 0 {
                    Text(L("cache_pinned_unpin_all_desc"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .onAppear {
            updateAll()
        }
        .alert(L("settings_alert_cache_cleared"), isPresented: $showClearedAlert) {
            Button(L("ok"), role: .cancel) { }
        }
    }
    
    private func updateAll() {
        updateDiskSpace()
        updateCacheSize()
        updateThumbnailCacheSize()
        updatePinnedCount()
    }
    
    private func updateDiskSpace() {
        let space = DiskSpaceHelper.currentDiskSpace()
        DispatchQueue.main.async {
            self.diskSpaceInfo = space
        }
    }
    
    private func triggerEvictionAndRefresh() {
        let vaultIds = appState.vaults.map { $0.id }
        let selected = selectedVaultId
        DispatchQueue.global(qos: .userInitiated).async {
            if selected == "all" {
                try? VirtualFileSystem.shared.cacheManager.cleanupIfNeeded()
                for vid in vaultIds {
                    try? CacheManager.forVault(vid).cleanupIfNeeded()
                }
            } else {
                try? CacheManager.forVault(selected).cleanupIfNeeded()
            }
            DispatchQueue.main.async {
                updateAll()
            }
        }
    }
    
    private func updatePinnedCount() {
        let vaultIds = appState.vaults.map { $0.id }
        let selected = selectedVaultId
        DispatchQueue.global(qos: .userInitiated).async {
            let count: Int
            if selected == "all" {
                count = CacheManager.allPinnedFileIdsAcrossAllVaults(knownVaultIds: vaultIds).count
            } else {
                count = CacheManager.forVault(selected).getAllPinnedFileIds().count
            }
            DispatchQueue.main.async {
                self.pinnedCount = count
            }
        }
    }
    
    private func unpinAll() {
        let vaultIds = appState.vaults.map { $0.id }
        let selected = selectedVaultId
        DispatchQueue.global(qos: .userInitiated).async {
            if selected == "all" {
                CacheManager.unpinAllAcrossAllVaults(knownVaultIds: vaultIds)
            } else {
                let mgr = CacheManager.forVault(selected)
                for fileId in mgr.getAllPinnedFileIds() {
                    mgr.unpinFile(fileId: fileId)
                }
            }
            DispatchQueue.main.async {
                updateAll()
            }
        }
    }
    
    private func updateCacheSize() {
        let vaultIds = appState.vaults.map { $0.id }
        let selected = selectedVaultId
        DispatchQueue.global(qos: .userInitiated).async {
            let dynamicSize: Int64
            let pinnedSize: Int64
            if selected == "all" {
                dynamicSize = CacheManager.totalDynamicCacheSizeAcrossAllVaults(knownVaultIds: vaultIds)
                pinnedSize = CacheManager.totalPinnedCacheSizeAcrossAllVaults(knownVaultIds: vaultIds)
            } else {
                let mgr = CacheManager.forVault(selected)
                dynamicSize = mgr.currentDynamicCacheSize()
                pinnedSize = mgr.currentPinnedCacheSize()
            }
            let formattedDynamic = ByteCountFormatter.string(fromByteCount: dynamicSize, countStyle: .file)
            let formattedPinned = ByteCountFormatter.string(fromByteCount: pinnedSize, countStyle: .file)
            DispatchQueue.main.async {
                self.dynamicCacheSize = formattedDynamic
                self.pinnedCacheSize = formattedPinned
            }
        }
    }
    
    private func updateThumbnailCacheSize() {
        DispatchQueue.global(qos: .userInitiated).async {
            let size = ThumbnailManager.shared.currentCacheSize()
            let formatted = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            DispatchQueue.main.async {
                self.thumbnailCacheSize = formatted
            }
        }
    }
    
    private func clearCache() {
        isClearing = true
        let vaultIds = appState.vaults.map { $0.id }
        let selected = selectedVaultId
        DispatchQueue.global(qos: .userInitiated).async {
            if selected == "all" {
                try? CacheManager.clearAllCacheAcrossAllVaults(knownVaultIds: vaultIds)
            } else {
                try? CacheManager.forVault(selected).clearAllCache()
            }
            DispatchQueue.main.async {
                updateAll()
                isClearing = false
                showClearedAlert = true
            }
        }
    }
    
    private func clearThumbnailCache() {
        ThumbnailManager.shared.clearAllCache()
        updateThumbnailCacheSize()
    }
}

struct AboutView: View {
    @ObservedObject private var localization = LocalizationManager.shared
    
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            
            if let logoImage = NSImage(named: "Logo") {
                Image(nsImage: logoImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(color: Color.black.opacity(0.15), radius: 6, x: 0, y: 3)
            } else {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.2), Color.blue.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 80, height: 80)
                    
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            
            VStack(spacing: 4) {
                Text(L("app_name"))
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text(appVersionString)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text(L("about_app_desc"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Divider()
                .padding(.horizontal, 40)
                .padding(.vertical, 4)
            
            HStack(spacing: 24) {
                FeatureBadge(icon: "lock.fill", text: L("about_feature_crypto"))
                FeatureBadge(icon: "externaldrive.fill", text: L("about_feature_protocol"))
                FeatureBadge(icon: "apple.logo", text: L("about_feature_fileprovider"))
                FeatureBadge(icon: "memorychip.fill", text: L("about_feature_cache"))
            }
            
            Spacer()
            
            Text("Copyright © 2026 李彦军. All rights reserved.")
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.7))
                .padding(.bottom, 12)
        }
        .padding()
    }
    
    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        var dateStr = ""
        if let execPath = Bundle.main.executablePath,
           let attrs = try? FileManager.default.attributesOfItem(atPath: execPath),
           let date = attrs[.modificationDate] as? Date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            dateStr = " (Build \(formatter.string(from: date)))"
        }
        return "v\(version) \(dateStr.isEmpty ? "Build " + build : dateStr)"
    }
}

struct FeatureBadge: View {
    let icon: String
    let text: String
    
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.secondary)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }
}