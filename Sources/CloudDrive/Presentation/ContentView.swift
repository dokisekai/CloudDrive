//
//  ContentView.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  主界面 - 现代 macOS 原生 NavigationSplitView 侧边栏分栏与卡片网格工作台
//

import SwiftUI
import AppKit
import CloudDriveCore

enum VaultFilter: String, CaseIterable, Identifiable {
    case all = "all"
    case mounted = "mounted"
    case unmounted = "unmounted"
    case encrypted = "encrypted"
    case direct = "direct"
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .all: return L("filter_all")
        case .mounted: return L("filter_mounted")
        case .unmounted: return L("filter_unmounted")
        case .encrypted: return L("filter_encrypted")
        case .direct: return L("filter_direct")
        }
    }
    
    var icon: String {
        switch self {
        case .all: return "tray.2.fill"
        case .mounted: return "externaldrive.fill.badge.checkmark"
        case .unmounted: return "externaldrive"
        case .encrypted: return "lock.shield.fill"
        case .direct: return "arrow.triangle.2.circlepath"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var localization = LocalizationManager.shared
    
    // 模态弹窗状态
    @State private var showingCreateVault = false
    @State private var createVaultInitialMode: VaultCreationMode = .createEncrypted
    @State private var showingSettings = false
    
    // 过滤与选择
    @State private var selectedFilter: VaultFilter = .all
    @State private var selectedProtocolFilter: StorageType? = nil
    @State private var selectedVaultId: String? = nil
    
    // 编辑与修改密码弹窗（全局单一实例提升）
    @State private var vaultToEdit: VaultInfo?
    @State private var vaultToChangePassword: VaultInfo?
    
    // 删除与卸载弹窗
    @State private var vaultToDelete: VaultInfo?
    @State private var showingDeleteAlert = false
    @State private var alertMessage = ""
    @State private var showAlert = false
    
    // 过滤后的保险库列表
    private var filteredVaults: [VaultInfo] {
        appState.vaults.filter { vault in
            // 如果单选了某个保险库
            if let targetId = selectedVaultId {
                return vault.id == targetId
            }
            
            // 协议过滤
            if let proto = selectedProtocolFilter, vault.storageType != proto {
                return false
            }
            
            // 状态过滤
            let matchesFilter: Bool = {
                switch selectedFilter {
                case .all: return true
                case .mounted: return vault.isMounted
                case .unmounted: return !vault.isMounted
                case .encrypted: return vault.isEncrypted
                case .direct: return !vault.isEncrypted
                }
            }()
            return matchesFilter
        }
    }
    
    var body: some View {
        NavigationSplitView {
            // MARK: - 左侧导航侧边栏
            VStack(spacing: 0) {
                // 顶部品牌区
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                LinearGradient(
                                    colors: [.blue, .cyan],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 28, height: 28)
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    }
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("app_name"))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.primary)
                        Text(subtitleText)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)
                
                Divider()
                    .padding(.horizontal, 10)
                
                // 侧边栏主体清单
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // 1. 核心视图分类
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L("sidebar_all_vaults"))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.secondary.opacity(0.8))
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                            
                            ForEach(VaultFilter.allCases) { filter in
                                SidebarFilterRow(
                                    title: filter.title,
                                    icon: filter.icon,
                                    count: vaultCount(for: filter),
                                    isSelected: selectedFilter == filter && selectedProtocolFilter == nil && selectedVaultId == nil,
                                    action: {
                                        selectedFilter = filter
                                        selectedProtocolFilter = nil
                                        selectedVaultId = nil
                                    }
                                )
                            }
                        }
                        
                        // 2. 存储协议分类 (若有不同协议)
                        let activeProtocols = StorageType.allCases.filter { type in
                            appState.vaults.contains { $0.storageType == type }
                        }
                        if !activeProtocols.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(L("sidebar_protocols"))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.secondary.opacity(0.8))
                                    .padding(.horizontal, 12)
                                
                                ForEach(activeProtocols, id: \.self) { proto in
                                    let pCount = appState.vaults.filter { $0.storageType == proto }.count
                                    SidebarFilterRow(
                                        title: proto.localizedName,
                                        icon: proto.iconName,
                                        count: pCount,
                                        iconColor: proto.themeColor,
                                        isSelected: selectedProtocolFilter == proto && selectedVaultId == nil,
                                        action: {
                                            selectedProtocolFilter = proto
                                            selectedVaultId = nil
                                        }
                                    )
                                }
                            }
                        }
                        
                        // 3. 快捷保险库列表
                        if !appState.vaults.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(L("sidebar_vaults"))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.secondary.opacity(0.8))
                                    .padding(.horizontal, 12)
                                
                                ForEach(appState.vaults) { vault in
                                    SidebarVaultItemRow(
                                        vault: vault,
                                        isSelected: selectedVaultId == vault.id,
                                        action: {
                                            if selectedVaultId == vault.id {
                                                selectedVaultId = nil
                                            } else {
                                                selectedVaultId = vault.id
                                                selectedProtocolFilter = nil
                                            }
                                        }
                                    )
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                
                Divider()
                    .padding(.horizontal, 10)
                
                // 底部快速操作区
                HStack(spacing: 8) {
                    Button {
                        showingSettings = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 12))
                            Text(L("sidebar_preferences"))
                                .font(.system(size: 11))
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    
                    Spacer()
                    
                    Button {
                        createVaultInitialMode = .createEncrypted
                        showingCreateVault = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .bold))
                            Text(L("sidebar_quick_add"))
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12))
                        .foregroundColor(.accentColor)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .frame(minWidth: 200, idealWidth: 220, maxWidth: 260)
            .background(Color(NSColor.controlBackgroundColor))
        } detail: {
            // MARK: - 右侧主展示画布区
            VStack(spacing: 0) {
                if appState.vaults.isEmpty {
                    EmptyVaultsView(
                        onCreateEncrypted: {
                            createVaultInitialMode = .createEncrypted
                            showingCreateVault = true
                        },
                        onOpenExisting: {
                            createVaultInitialMode = .openExisting
                            showingCreateVault = true
                        },
                        onDirectWebDAV: {
                            createVaultInitialMode = .directWebDAV
                            showingCreateVault = true
                        }
                    )
                } else if filteredVaults.isEmpty {
                    VStack(spacing: 14) {
                        Spacer()
                        Image(systemName: "tray")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary.opacity(0.5))
                        
                        Text(L("search_no_results"))
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        Button(L("filter_all")) {
                            selectedFilter = .all
                            selectedProtocolFilter = nil
                            selectedVaultId = nil
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.windowBackgroundColor))
                } else {
                    VaultListView(
                        vaults: filteredVaults,
                        appState: appState,
                        onRequestDelete: { vault in
                            if vault.isMounted {
                                alertMessage = L("alert_vault_mounted_cannot_delete", vault.name)
                                showAlert = true
                            } else {
                                vaultToDelete = vault
                                showingDeleteAlert = true
                            }
                        },
                        onEdit: { vault in
                            vaultToEdit = vault
                        },
                        onChangePassword: { vault in
                            vaultToChangePassword = vault
                        }
                    )
                }
            }
            .frame(minWidth: 560, minHeight: 480)
            .navigationTitle(L("app_name"))
            .navigationSubtitle(subtitleText)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button {
                            createVaultInitialMode = .createEncrypted
                            showingCreateVault = true
                        } label: {
                            Label(L("toolbar_new_encrypted_vault"), systemImage: "lock.shield.fill")
                        }
                        
                        Button {
                            createVaultInitialMode = .openExisting
                            showingCreateVault = true
                        } label: {
                            Label(L("toolbar_open_existing_vault"), systemImage: "lock.open.fill")
                        }
                        
                        Divider()
                        
                        Button {
                            createVaultInitialMode = .directWebDAV
                            showingCreateVault = true
                        } label: {
                            Label(L("toolbar_direct_storage"), systemImage: "arrow.triangle.2.circlepath")
                        }
                    } label: {
                        Label(L("toolbar_add_vault"), systemImage: "plus")
                    }
                    .menuStyle(.borderedButton)
                    .help(L("toolbar_add_vault"))
                    
                    Button {
                        Task {
                            appState.refreshMountedDomains()
                            await appState.refreshAllMountedVaults()
                            StatusBarManager.shared.updateStatusIcon()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help(L("toolbar_refresh_tooltip"))
                    
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help(L("toolbar_settings_tooltip"))
                }
            }
            .sheet(isPresented: $showingCreateVault) {
                CreateVaultView(initialMode: createVaultInitialMode)
                    .id(createVaultInitialMode)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .environmentObject(appState)
            }
            .sheet(isPresented: $appState.showUnlockVault) {
                if let vault = appState.selectedVaultForUnlock {
                    UnlockVaultView(vault: vault)
                }
            }
            .sheet(item: $vaultToEdit) { vault in
                EditVaultSheet(vault: vault)
                    .environmentObject(appState)
            }
            .sheet(item: $vaultToChangePassword) { vault in
                ChangeVaultPasswordSheet(vault: vault)
                    .environmentObject(appState)
            }
            .alert(L("tip"), isPresented: $showAlert) {
                Button(L("confirm"), role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
            .alert(L("alert_confirm_remove_vault"), isPresented: $showingDeleteAlert) {
                Button(L("cancel"), role: .cancel) {
                    vaultToDelete = nil
                }
                Button(L("remove"), role: .destructive) {
                    if let vault = vaultToDelete {
                        appState.deleteVault(vault)
                        vaultToDelete = nil
                    }
                }
            } message: {
                if let vault = vaultToDelete {
                    Text(L("alert_confirm_remove_vault_msg", vault.name))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("OpenSettingsModal"))) { _ in
                showingSettings = true
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("OpenCreateVaultModal"))) { notif in
                if let mode = notif.object as? VaultCreationMode {
                    createVaultInitialMode = mode
                }
                showingCreateVault = true
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("TriggerRefreshAllVaults"))) { _ in
                Task {
                    appState.refreshMountedDomains()
                    await appState.refreshAllMountedVaults()
                    StatusBarManager.shared.updateStatusIcon()
                }
            }
        }
        .frame(minWidth: 800, idealWidth: 920, minHeight: 520, idealHeight: 620)
    }
    
    private var subtitleText: String {
        let count = appState.vaults.count
        if count == 0 {
            return L("nav_subtitle_default")
        }
        let mountedCount = appState.vaults.filter(\.isMounted).count
        return L("nav_subtitle_counts", count, mountedCount)
    }
    
    private func vaultCount(for filter: VaultFilter) -> Int {
        switch filter {
        case .all:       return appState.vaults.count
        case .mounted:   return appState.vaults.filter(\.isMounted).count
        case .unmounted: return appState.vaults.filter { !$0.isMounted }.count
        case .encrypted: return appState.vaults.filter(\.isEncrypted).count
        case .direct:    return appState.vaults.filter { !$0.isEncrypted }.count
        }
    }
}

// MARK: - 侧边栏行组件

struct SidebarFilterRow: View {
    let title: String
    let icon: String
    let count: Int
    var iconColor: Color = .primary
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? .white : iconColor.opacity(0.8))
                    .frame(width: 18)
                
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .white : .primary)
                
                Spacer()
                
                Text("\(count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor : (isHovered ? Color.secondary.opacity(0.08) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { isHovered = $0 }
    }
}

struct SidebarVaultItemRow: View {
    let vault: VaultInfo
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(vault.isMounted ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
                
                Image(systemName: vault.storageType.iconName)
                    .font(.system(size: 10))
                    .foregroundColor(vault.storageType.themeColor)
                
                Text(vault.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundColor(isSelected ? .accentColor : .primary)
                
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? Color.secondary.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { isHovered = $0 }
    }
}


struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(AppState())
    }
}
