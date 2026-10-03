//
//  RecycleBinView.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  回收站管理界面 (支持软删除管理、还原、彻底删除、清空与全局/单库开关)
//

import SwiftUI
import AppKit
import CloudDriveCore

struct RecycleBinView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var localization = LocalizationManager.shared
    
    @State private var isEnabled: Bool = true
    @State private var selectedVaultId: String = "all"
    @State private var retentionDays: Int = RecycleBinConfig.retentionDays
    @State private var searchText: String = ""
    @State private var trashedItems: [RecycleBinItem] = []
    
    // 弹窗与确认状态
    @State private var itemToDelete: RecycleBinItem? = nil
    @State private var showingEmptyAlert: Bool = false
    @State private var showingDeleteAlert: Bool = false
    @State private var alertMessage: String = ""
    @State private var isProcessing: Bool = false
    
    var filteredItems: [RecycleBinItem] {
        trashedItems.filter { item in
            let matchesVault = (selectedVaultId == "all") || (item.vaultId == selectedVaultId)
            let matchesSearch = searchText.isEmpty || item.name.localizedCaseInsensitiveContains(searchText)
            return matchesVault && matchesSearch
        }
    }
    
    var totalSizeFormatted: String {
        let total = filteredItems.reduce(0) { $0 + $1.size }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: - 顶栏控制区域 (开关、筛选、搜索、清空)
            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    // 回收站功能开关
                    Toggle(isOn: $isEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("recycle_bin_enable_title"))
                                .font(.system(size: 13, weight: .semibold))
                            Text(L("recycle_bin_enable_desc"))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .onChange(of: isEnabled) { newValue in
                        if selectedVaultId != "all" {
                            RecycleBinConfig.setEnabled(newValue, for: selectedVaultId)
                        } else {
                            for vault in appState.vaults {
                                RecycleBinConfig.setEnabled(newValue, for: vault.id)
                            }
                        }
                    }
                    
                    Spacer()
                    
                    // 保留期限设置
                    Picker(L("vault_recycle_bin_retention"), selection: $retentionDays) {
                        Text(L("vault_recycle_bin_retention_days", 7)).tag(7)
                        Text(L("vault_recycle_bin_retention_days", 14)).tag(14)
                        Text(L("vault_recycle_bin_retention_days", 30)).tag(30)
                        Text(L("vault_recycle_bin_retention_days", 90)).tag(90)
                        Text(L("vault_recycle_bin_retention_forever")).tag(0)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                    .onChange(of: retentionDays) { newDays in
                        RecycleBinConfig.retentionDays = newDays
                    }
                    
                    // 存储库筛选
                    Picker(L("recycle_bin_filter_vault"), selection: $selectedVaultId) {
                        Text(L("recycle_bin_all_vaults")).tag("all")
                        ForEach(appState.vaults) { vault in
                            Text(vault.name).tag(vault.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 170)
                    .onChange(of: selectedVaultId) { newVault in
                        updateToggleForSelection(newVault)
                        loadItems()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                
                Divider()
                
                // 搜索栏与批量操作栏
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField(L("recycle_bin_search_placeholder"), text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
                    
                    Spacer()
                    
                    // 统计提示
                    Text(L("recycle_bin_summary", filteredItems.count, totalSizeFormatted))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    // 全部还原
                    if !filteredItems.isEmpty {
                        Button(action: restoreAll) {
                            Label(L("recycle_bin_restore_all"), systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isProcessing)
                    }
                    
                    // 清空回收站
                    Button(role: .destructive, action: { showingEmptyAlert = true }) {
                        Label(L("recycle_bin_empty"), systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(filteredItems.isEmpty || isProcessing)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // MARK: - 文件列表或空状态
            if filteredItems.isEmpty {
                emptyStateView
            } else {
                itemList
            }
        }
        .onAppear {
            retentionDays = RecycleBinConfig.retentionDays
            updateToggleForSelection(selectedVaultId)
            loadItems()
            Task {
                let purged = await RecycleBinManager.shared.purgeExpiredItems()
                if purged > 0 {
                    await MainActor.run { loadItems() }
                }
            }
        }
        .alert(L("recycle_bin_empty_confirm_title"), isPresented: $showingEmptyAlert) {
            Button(L("cancel"), role: .cancel) { }
            Button(L("recycle_bin_confirm_empty"), role: .destructive) {
                emptyTrash()
            }
        } message: {
            Text(L("recycle_bin_empty_confirm_msg"))
        }
        .alert(L("recycle_bin_delete_confirm_title"), isPresented: $showingDeleteAlert) {
            Button(L("cancel"), role: .cancel) { }
            Button(L("recycle_bin_confirm_delete"), role: .destructive) {
                if let item = itemToDelete {
                    permanentlyDelete(item)
                }
            }
        } message: {
            Text(L("recycle_bin_delete_confirm_msg", itemToDelete?.name ?? ""))
        }
    }
    
    // MARK: - 空状态视图
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "trash")
                .font(.system(size: 42))
                .foregroundColor(.secondary.opacity(0.6))
            Text(L("recycle_bin_empty_state_title"))
                .font(.headline)
                .foregroundColor(.secondary)
            Text(L("recycle_bin_empty_state_desc"))
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
    }
    
    // MARK: - 文件列表
    private var itemList: some View {
        List {
            ForEach(filteredItems) { item in
                HStack(spacing: 12) {
                    Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                        .font(.system(size: 20))
                        .foregroundColor(item.isDirectory ? .yellow : .blue)
                        .frame(width: 28)
                    
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(item.name)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            
                            if let vaultName = appState.vaults.first(where: { $0.id == item.vaultId })?.name {
                                Text(vaultName)
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.15))
                                    .cornerRadius(4)
                            }
                        }
                        
                        HStack(spacing: 12) {
                            Text(L("recycle_bin_deleted_at", formatDate(item.deletedAt)))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            
                            if !item.isDirectory {
                                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    Spacer()
                    
                    // 操作按钮
                    HStack(spacing: 8) {
                        Button(action: { restoreItem(item) }) {
                            Label(L("recycle_bin_restore"), systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        Button(role: .destructive, action: {
                            itemToDelete = item
                            showingDeleteAlert = true
                        }) {
                            Label(L("recycle_bin_delete_forever"), systemImage: "xmark")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }
    
    // MARK: - 业务逻辑
    
    private func updateToggleForSelection(_ vaultId: String) {
        if vaultId == "all" {
            if appState.vaults.isEmpty {
                isEnabled = false
            } else {
                isEnabled = appState.vaults.allSatisfy { RecycleBinConfig.isEnabled(for: $0.id) }
            }
        } else {
            isEnabled = RecycleBinConfig.isEnabled(for: vaultId)
        }
    }
    
    private func loadItems() {
        let targetVault = selectedVaultId == "all" ? nil : selectedVaultId
        trashedItems = RecycleBinManager.shared.listItems(vaultId: targetVault)
    }
    
    private func restoreItem(_ item: RecycleBinItem) {
        guard !isProcessing else { return }
        isProcessing = true
        Task {
            do {
                let vfs = VirtualFileSystem.shared
                let sync = SyncManager.shared
                let cache = CacheManager.shared
                try await RecycleBinManager.shared.restore(
                    id: item.id,
                    vfs: vfs,
                    syncManager: sync,
                    cacheManager: cache
                )
                await MainActor.run {
                    loadItems()
                    isProcessing = false
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                }
            }
        }
    }
    
    private func restoreAll() {
        guard !isProcessing else { return }
        isProcessing = true
        Task {
            let vfs = VirtualFileSystem.shared
            let sync = SyncManager.shared
            let cache = CacheManager.shared
            for item in filteredItems {
                _ = try? await RecycleBinManager.shared.restore(
                    id: item.id,
                    vfs: vfs,
                    syncManager: sync,
                    cacheManager: cache
                )
            }
            await MainActor.run {
                loadItems()
                isProcessing = false
            }
        }
    }
    
    private func permanentlyDelete(_ item: RecycleBinItem) {
        guard !isProcessing else { return }
        isProcessing = true
        Task {
            do {
                let vfs = VirtualFileSystem.shared
                let sync = SyncManager.shared
                try await RecycleBinManager.shared.deletePermanently(
                    id: item.id,
                    vfs: vfs,
                    syncManager: sync
                )
                await MainActor.run {
                    loadItems()
                    itemToDelete = nil
                    isProcessing = false
                }
            } catch {
                await MainActor.run {
                    itemToDelete = nil
                    isProcessing = false
                }
            }
        }
    }
    
    private func emptyTrash() {
        guard !isProcessing else { return }
        isProcessing = true
        Task {
            do {
                let vfs = VirtualFileSystem.shared
                let sync = SyncManager.shared
                let targetVault = selectedVaultId == "all" ? nil : selectedVaultId
                try await RecycleBinManager.shared.emptyTrash(
                    vaultId: targetVault,
                    vfs: vfs,
                    syncManager: sync
                )
                await MainActor.run {
                    loadItems()
                    isProcessing = false
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                }
            }
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
