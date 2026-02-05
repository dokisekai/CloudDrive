//
//  ContentView.swift
//  CloudDrive
//
//  主界面 - 仅保留保险库管理功能
//

//
//  ContentView.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//

import SwiftUI
import CloudDriveCore

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingCreateVault = false
    @State private var showingSettings = false
    @State private var showingDeleteWarning = false
    @State private var deleteWarningMessage = ""
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                if appState.vaults.isEmpty {
                    // 无保险库时显示欢迎界面
                    VStack(spacing: 20) {
                        Image(systemName: "externaldrive.badge.icloud")
                            .font(.system(size: 80))
                            .foregroundColor(.blue)
                        
                        Text("欢迎使用 CloudDrive")
                            .font(.title)
                            .fontWeight(.bold)
                        
                        Text("创建保险库以开始使用")
                            .font(.body)
                            .foregroundColor(.secondary)
                        
                        Button(action: {
                            showingCreateVault = true
                        }) {
                            Label("创建保险库", systemImage: "plus.circle.fill")
                                .font(.headline)
                                .padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                    }
                    .padding()
                } else {
                    // 保险库列表
                    List {
                        ForEach(appState.vaults) { vault in
                            VaultRow(vaultId: vault.id, appState: appState)
                        }
                        .onDelete(perform: deleteVaults)
                    }
                }
            }
            .navigationTitle("CloudDrive")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        showingCreateVault = true
                    }) {
                        Label("创建保险库", systemImage: "plus")
                    }
                }
                
                ToolbarItem(placement: .automatic) {
                    Button(action: {
                        showingSettings = true
                    }) {
                        Label("设置", systemImage: "gear")
                    }
                }
            }
            .sheet(isPresented: $showingCreateVault) {
                CreateVaultView()
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .alert("无法删除", isPresented: $showingDeleteWarning) {
                Button("确定", role: .cancel) { }
            } message: {
                Text(deleteWarningMessage)
            }
        }
    }
    
    private func deleteVaults(at offsets: IndexSet) {
        // 首先检查所有选中的保险库是否都未挂载
        let vaultsToDelete = offsets.map { appState.vaults[$0] }
        let mountedVaults = vaultsToDelete.filter { $0.isMounted }
        
        if !mountedVaults.isEmpty {
            // 显示警告，不允许删除已挂载的保险库
            let vaultNames = mountedVaults.map { "\($0.name)" }.joined(separator: ", ")
            print("⚠️ ContentView: 无法删除已挂载的保险库: \(vaultNames)")
            deleteWarningMessage = "保险库 \"\(vaultNames)\" 当前已挂载，请先卸载后再删除。"
            showingDeleteWarning = true
            return
        }
        
        // 所有保险库都未挂载，批量删除
        for vault in vaultsToDelete {
            appState.deleteVault(vault)
        }
    }
}

struct VaultRow: View {
    let vaultId: String
    @ObservedObject var appState: AppState
    @State private var showingInFinder = false
    @State private var showingUnmountConfirmation = false
    @State private var showingMountConfirmation = false
    @State private var showingDeleteConfirmation = false
    @State private var isMounting = false
    @State private var mountError: String?
    
    // 从 vaults 数组动态获取当前 vault，确保实时更新
    private var vault: VaultInfo? {
        appState.vaults.first { $0.id == vaultId }
    }
    
    var body: some View {
        guard let vault = vault else {
            return AnyView(Text("保险库不存在").foregroundColor(.red))
        }

        return AnyView(
            HStack {
                Image(systemName: vault.isMounted ? "externaldrive.fill.badge.checkmark" : "externaldrive.fill")
                    .font(.title2)
                    .foregroundColor(vault.isMounted ? .green : .blue)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(vault.name)
                            .font(.headline)

                        if vault.isMounted {
                            Text("已挂载")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.2))
                                .foregroundColor(.green)
                                .cornerRadius(4)
                        }
                    }

                    if let webdavURL = vault.webdavURL {
                        Text(webdavURL)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text("创建于 \(vault.createdAt, style: .date)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if vault.isMounted {
                    Button(action: {
                        showingUnmountConfirmation = true
                    }) {
                        Label("卸载", systemImage: "eject")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .alert("确认卸载", isPresented: $showingUnmountConfirmation) {
                        Button("取消", role: .cancel) { }
                        Button("卸载", role: .destructive) {
                            appState.unmountVault(vault)
                        }
                    } message: {
                        Text("确定要卸载保险库 \"\(vault.name)\" 吗？")
                    }
                } else {
                    // 未挂载时显示挂载和删除按钮
                    HStack(spacing: 8) {
                        Button(action: {
                            showingMountConfirmation = true
                        }) {
                            Label("挂载", systemImage: "play.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isMounting || vault.isMounted)
                        .alert("确认挂载", isPresented: $showingMountConfirmation) {
                            Button("取消", role: .cancel) { }
                            Button("挂载") {
                                Task {
                                    await mountVault(vault)
                                }
                            }
                        } message: {
                            Text("确定要挂载保险库 \"\(vault.name)\" 吗？")
                        }
                        .alert("挂载失败", isPresented: Binding<Bool>(
                            get: { mountError != nil },
                            set: { if !$0 { mountError = nil } }
                        )) {
                            Button("确定", role: .cancel) { }
                        } message: {
                            if let error = mountError {
                                Text(error)
                            }
                        }

                        Button(action: {
                            showingDeleteConfirmation = true
                        }) {
                            Label("删除", systemImage: "trash")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.bordered)
                        .disabled(vault.isMounted)
                        .alert("确认删除", isPresented: $showingDeleteConfirmation) {
                            Button("取消", role: .cancel) { }
                            Button("删除", role: .destructive) {
                                appState.deleteVault(vault)
                            }
                        } message: {
                            Text("确定要删除保险库 \"\(vault.name)\" 吗？此操作不可恢复。")
                        }
                    }

                    Button(action: {
                        openInFinder()
                    }) {
                        Label("在 Finder 中打开", systemImage: "folder")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!vault.isMounted)
                }
            }
            .padding(.vertical, 8)
            .opacity(vault.isMounted ? 1.0 : 0.6)
        )
    }
    
    private func mountVault(_ vault: VaultInfo) async {
        isMounting = true
        mountError = nil
        
        do {
            try await appState.remountVault(vault)
        } catch {
            mountError = error.localizedDescription
        }
        
        isMounting = false
    }
    
    private func openInFinder() {
        // 打开 Finder 中的虚拟盘
        let workspace = NSWorkspace.shared
        let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        workspace.open(finderURL)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(AppState())
    }
}
