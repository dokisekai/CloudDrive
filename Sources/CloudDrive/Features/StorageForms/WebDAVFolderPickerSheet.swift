//
//  WebDAVFolderPickerSheet.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  WebDAV 远端文件夹浏览选择器弹窗
//

import SwiftUI
import CloudDriveCore

struct WebDAVFolderPickerSheet: View {
    let url: String
    let username: String
    let password: String
    @Binding var selectedPath: String
    var onSelect: ((String) -> Void)? = nil
    
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    @ObservedObject private var localization = LocalizationManager.shared
    
    @State private var currentPath: String
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var currentIsVault = false
    @State private var folders: [RemoteFolderItem] = []
    
    init(url: String, username: String, password: String, selectedPath: Binding<String>, onSelect: ((String) -> Void)? = nil) {
        self.url = url
        self.username = username
        self.password = password
        self._selectedPath = selectedPath
        self.onSelect = onSelect
        let initial = selectedPath.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        self._currentPath = State(initialValue: initial.isEmpty ? "/" : initial)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部导航栏
            HStack {
                Text(L("picker_title"))
                    .font(.headline)
                Spacer()
                Button(L("close")) { dismiss() }
            }
            .padding()
            
            Divider()
            
            // 路径导航栏
            HStack(spacing: 8) {
                Button(action: { navigateTo("/") }) {
                    Image(systemName: "house.fill")
                }
                .buttonStyle(.bordered)
                .help(L("picker_home_tooltip"))
                
                if currentPath != "/" {
                    Button(action: navigateUp) {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .help(L("picker_up_tooltip"))
                }
                
                Text(currentPath)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                Button(action: { loadPath(currentPath) }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help(L("refresh"))
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            Divider()
            
            // 当前目录如果是保险库，显示高亮条
            if currentIsVault {
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundColor(.green)
                        .font(.title2)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("picker_vault_detected"))
                            .font(.headline)
                            .foregroundColor(.green)
                        Text(L("picker_vault_detected_desc"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Button(L("picker_select_current_dir")) {
                        chooseAndDismiss(currentPath)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(Color.green.opacity(0.12))
                .cornerRadius(8)
                .padding(.horizontal)
                .padding(.top, 8)
            }
            
            // 内容区域
            ZStack {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text(L("picker_loading"))
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.red)
                        Text(L("picker_load_failed", err))
                            .font(.callout)
                            .foregroundColor(.red)
                        Button(L("picker_retry")) { loadPath(currentPath) }
                            .buttonStyle(.bordered)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if folders.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "folder")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text(L("picker_no_subfolders"))
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(folders) { item in
                            HStack {
                                Image(systemName: item.isVault ? "lock.shield.fill" : "folder.fill")
                                    .foregroundColor(item.isVault ? .orange : .blue)
                                    .font(.title3)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(item.name)
                                            .font(.body)
                                            .fontWeight(item.isVault ? .semibold : .regular)
                                        
                                        if item.isVault {
                                            Text(L("picker_encrypted_vault_badge"))
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.orange.opacity(0.2))
                                                .foregroundColor(.orange)
                                                .cornerRadius(4)
                                        }
                                    }
                                    Text(item.path)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                HStack(spacing: 8) {
                                    Button(L("picker_enter")) {
                                        navigateTo(item.path)
                                    }
                                    .buttonStyle(.bordered)
                                    
                                    if item.isVault {
                                        Button(L("picker_select_this_vault")) {
                                            chooseAndDismiss(item.path)
                                        }
                                        .buttonStyle(.borderedProminent)
                                    } else {
                                        Button(L("picker_select")) {
                                            chooseAndDismiss(item.path)
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(maxHeight: .infinity)
            
            Divider()
            
            // 底部选择条
            HStack {
                Text(L("picker_selected_path", currentPath))
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button(L("picker_select_current_dir_with_path", currentPath)) {
                    chooseAndDismiss(currentPath)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 580, height: 500)
        .onAppear {
            loadPath(currentPath)
        }
    }
    
    private func navigateTo(_ path: String) {
        currentPath = path
        loadPath(path)
    }
    
    private func navigateUp() {
        guard currentPath != "/" else { return }
        var components = currentPath.split(separator: "/").map(String.init)
        if !components.isEmpty {
            components.removeLast()
        }
        let parent = components.isEmpty ? "/" : "/" + components.joined(separator: "/")
        navigateTo(parent)
    }
    
    private func chooseAndDismiss(_ path: String) {
        selectedPath = path
        onSelect?(path)
        dismiss()
    }
    
    private func loadPath(_ path: String) {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let result = try await appState.browseWebDAVDirectory(
                    url: url,
                    username: username,
                    password: password,
                    path: path
                )
                await MainActor.run {
                    self.currentIsVault = result.currentIsVault
                    self.folders = result.folders
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}

