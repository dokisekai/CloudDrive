//
//  VaultCardView.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  单个保险库卡片组件 (现代 macOS 桌面应用设计，支持多协议与平滑交互)
//

import SwiftUI
import AppKit
import FileProvider
import CloudDriveCore

struct VaultCardView: View {
    let vaultId: String
    @ObservedObject var appState: AppState
    @ObservedObject private var localization = LocalizationManager.shared
    let onRequestDelete: () -> Void
    var onEdit: ((VaultInfo) -> Void)? = nil
    var onChangePassword: ((VaultInfo) -> Void)? = nil
    
    @State private var isMounting = false
    @State private var mountErrorMessage: String?
    @State private var showingUnmountAlert = false
    @State private var isHovered = false
    @State private var copiedTooltip = false
    
    private var vault: VaultInfo? {
        appState.vaults.first { $0.id == vaultId }
    }
    
    var body: some View {
        guard let vault = vault else {
            return AnyView(EmptyView())
        }
        
        let isMounted = vault.isMounted
        let endpoint = displayEndpoint(for: vault)
        
        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                // 1. 卡片主体内容区
                VStack(alignment: .leading, spacing: 14) {
                    // 顶部栏：协议图标 + 名称与状态徽章
                    HStack(alignment: .top, spacing: 12) {
                        // 协议图标徽章
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            vault.storageType.themeColor.opacity(0.18),
                                            vault.storageType.themeColor.opacity(0.06)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 44, height: 44)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(vault.storageType.themeColor.opacity(0.25), lineWidth: 1)
                                )
                            
                            if isMounting {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: vault.storageType.iconName)
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundColor(vault.storageType.themeColor)
                            }
                        }
                        
                        // 标题与路径
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(vault.name)
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                
                                Spacer(minLength: 4)
                                
                                // 挂载状态指示器
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(isMounted ? Color.green : Color.secondary.opacity(0.4))
                                        .frame(width: 7, height: 7)
                                    Text(isMounted ? L("vault_status_mounted") : L("vault_status_unmounted"))
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(isMounted ? Color.green.opacity(0.12) : Color.secondary.opacity(0.08))
                                .foregroundColor(isMounted ? .green : .secondary)
                                .cornerRadius(6)
                            }
                            
                            // 路径 / 远端地址
                            HStack(spacing: 5) {
                                Image(systemName: vault.isLocal ? "internaldrive" : "link")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary.opacity(0.8))
                                
                                Text(endpoint)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                
                                Button {
                                    copyPath(endpoint)
                                } label: {
                                    Image(systemName: copiedTooltip ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 9))
                                        .foregroundColor(copiedTooltip ? .green : .secondary)
                                }
                                .buttonStyle(.plain)
                                .help(L("vault_card_copy_path_tooltip"))
                            }
                        }
                    }
                    
                    // 中间标签栏 (协议类别、加密方式、自启动挂载)
                    HStack(spacing: 6) {
                        // 协议标签
                        HStack(spacing: 3) {
                            Text(vault.storageType.localizedName)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(vault.storageType.themeColor.opacity(0.1))
                        .foregroundColor(vault.storageType.themeColor)
                        .cornerRadius(4)
                        
                        // 加密保护标签
                        if vault.isEncrypted {
                            HStack(spacing: 3) {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 8))
                                Text(L("badge_secure_aes"))
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12))
                            .foregroundColor(.orange)
                            .cornerRadius(4)
                        } else {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 8))
                                Text(L("badge_direct_mode"))
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.1))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                        }
                        
                        // 自动挂载标签
                        Button {
                            appState.toggleAutoMount(for: vault.id)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: vault.isAutoMount ? "bolt.circle.fill" : "bolt.slash.circle")
                                    .font(.system(size: 9))
                                Text(vault.isAutoMount ? L("card_auto_mount_on") : L("card_auto_mount_off"))
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(vault.isAutoMount ? Color.purple.opacity(0.1) : Color.secondary.opacity(0.08))
                            .foregroundColor(vault.isAutoMount ? .purple : .secondary)
                            .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                        .help(vault.isAutoMount ? L("vault_edit_auto_mount_desc") : L("vault_edit_auto_mount"))
                        
                        Spacer()
                        
                        Text(L("vault_card_added_on", vault.createdAt.formatted(date: .abbreviated, time: .omitted)))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
                .padding(16)
                
                Divider()
                
                // 2. 底部操作按钮栏
                HStack(spacing: 8) {
                    if isMounted {
                        Button {
                            openInFinder(vault: vault)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 11))
                                Text(L("vault_card_open_in_finder"))
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        
                        Button {
                            triggerUnmount(vault)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "eject.fill")
                                    .font(.system(size: 10))
                                Text(L("vault_card_unmount"))
                                    .font(.system(size: 12))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    } else {
                        Button {
                            doMount(vault)
                        } label: {
                            HStack(spacing: 5) {
                                if isMounting {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                        .frame(width: 12, height: 12)
                                    Text(L("vault_card_mounting"))
                                        .font(.system(size: 12, weight: .medium))
                                } else {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 10))
                                    Text(L("vault_card_mount"))
                                        .font(.system(size: 12, weight: .medium))
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(isMounting)
                        
                        Button(action: onRequestDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .help(L("vault_card_remove_tooltip"))
                    }
                    
                    Spacer()
                    
                    // 更多选项菜单按钮
                    Menu {
                        if isMounted {
                            Button {
                                openInFinder(vault: vault)
                            } label: {
                                Label(L("vault_card_open_in_finder"), systemImage: "folder")
                            }
                            Button {
                                triggerUnmount(vault)
                            } label: {
                                Label(L("vault_card_unmount_menu"), systemImage: "eject")
                            }
                        } else {
                            Button {
                                doMount(vault)
                            } label: {
                                Label(L("vault_card_mount_menu"), systemImage: "play")
                            }
                        }
                        
                        Divider()
                        
                        Button {
                            onEdit?(vault)
                        } label: {
                            Label(L("vault_card_edit_menu"), systemImage: "pencil")
                        }
                        
                        if vault.isEncrypted {
                            Button {
                                onChangePassword?(vault)
                            } label: {
                                Label(L("menu_change_vault_password"), systemImage: "key.horizontal")
                            }
                        }
                        
                        Button {
                            copyPath(endpoint)
                        } label: {
                            Label(L("vault_card_copy_path_tooltip"), systemImage: "doc.on.doc")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 24, height: 24)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
                
                // 3. 挂载错误提示条
                if let err = mountErrorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 12))
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                            .lineLimit(2)
                        Spacer()
                        Button {
                            mountErrorMessage = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.08))
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        isHovered
                            ? vault.storageType.themeColor.opacity(0.4)
                            : (isMounted ? Color.green.opacity(0.2) : Color(NSColor.separatorColor).opacity(0.35)),
                        lineWidth: isHovered ? 1.5 : 1
                    )
            )
            .shadow(
                color: isHovered ? Color.black.opacity(0.08) : Color.black.opacity(0.02),
                radius: isHovered ? 8 : 2,
                x: 0,
                y: isHovered ? 3 : 1
            )
            .scaleEffect(isHovered ? 1.008 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
            .contextMenu {
                if isMounted {
                    Button {
                        openInFinder(vault: vault)
                    } label: {
                        Label(L("vault_card_open_in_finder"), systemImage: "folder")
                    }
                    
                    Button {
                        triggerUnmount(vault)
                    } label: {
                        Label(L("vault_card_unmount_menu"), systemImage: "eject")
                    }
                } else {
                    Button {
                        doMount(vault)
                    } label: {
                        Label(L("vault_card_mount_menu"), systemImage: "play")
                    }
                }
                
                Divider()
                
                Button {
                    onEdit?(vault)
                } label: {
                    Label(L("vault_card_edit_menu"), systemImage: "pencil")
                }
                
                if vault.isEncrypted {
                    Button {
                        onChangePassword?(vault)
                    } label: {
                        Label(L("menu_change_vault_password"), systemImage: "key.horizontal")
                    }
                }
                
                Button {
                    appState.toggleAutoMount(for: vault.id)
                } label: {
                    Label(vault.isAutoMount ? L("vault_status_automount") : L("vault_status_manual"), systemImage: vault.isAutoMount ? "bolt.circle" : "bolt.slash.circle")
                }
                
                Button {
                    copyPath(endpoint)
                } label: {
                    Label(L("vault_card_copy_path_tooltip"), systemImage: "doc.on.doc")
                }
                
                Divider()
                
                Button(role: .destructive, action: onRequestDelete) {
                    Label(L("vault_card_remove_tooltip"), systemImage: "trash")
                }
                .disabled(isMounted)
            }
            .alert(L("alert_confirm_unmount"), isPresented: $showingUnmountAlert) {
                Button(L("cancel"), role: .cancel) { }
                Button(L("vault_card_unmount"), role: .destructive) {
                    appState.unmountVault(vault)
                }
            } message: {
                Text(L("alert_confirm_unmount_msg", vault.name))
            }
        )
    }
    
    private func triggerUnmount(_ vault: VaultInfo) {
        if AppSettings.shared.confirmBeforeUnmount {
            showingUnmountAlert = true
        } else {
            appState.unmountVault(vault)
        }
    }
    
    private func displayEndpoint(for vault: VaultInfo) -> String {
        if let config = vault.storageConfig {
            switch config {
            case .webdav(let c): return c.baseURL
            case .s3(let c): return "\(c.bucket) @ \(c.endpoint)"
            case .smb(let c): return "smb://\(c.host)/\(c.share)"
            case .ftp(let c): return "ftp://\(c.host):\(c.port)\(c.path)"
            case .pan123(let c):
                let root = c.rootFolderID == 0 ? "根目录" : "ID: \(c.rootFolderID)"
                return "123云盘 (\(root))"
            case .local(let c): return c.path
            }
        }
        if let url = vault.webdavURL, !url.isEmpty {
            return url
        }
        return vault.storagePath
    }
    
    private func iconName(for vault: VaultInfo) -> String {
        if vault.isMounted {
            return "externaldrive.fill.badge.checkmark"
        }
        if vault.isEncrypted {
            return "lock.shield.fill"
        }
        return "arrow.triangle.2.circlepath"
    }
    
    private func copyPath(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        withAnimation {
            copiedTooltip = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copiedTooltip = false
        }
    }
    
    private func doMount(_ vault: VaultInfo) {
        isMounting = true
        mountErrorMessage = nil
        
        Task {
            do {
                try await appState.remountVault(vault)
            } catch {
                let desc = error.localizedDescription
                let needsCredentials =
                    desc.contains("无法获取保险库加密密码") ||
                    desc.contains("Unable to obtain vault encryption password") ||
                    desc == L("err_cannot_get_password") ||
                    desc.contains("无法获取 WebDAV 密码") ||
                    desc.contains("Unable to obtain WebDAV password") ||
                    desc == L("err_cannot_get_webdav_password")
                
                if needsCredentials {
                    await MainActor.run {
                        appState.selectedVaultForUnlock = vault
                        appState.showUnlockVault = true
                    }
                } else {
                    await MainActor.run {
                        mountErrorMessage = desc
                    }
                }
            }
            await MainActor.run {
                isMounting = false
            }
        }
    }
    
    private func openInFinder(vault: VaultInfo) {
        if let manager = FileProviderDomainService.shared.getManager(for: vault) {
            manager.getUserVisibleURL(for: NSFileProviderItemIdentifier.rootContainer) { url, error in
                DispatchQueue.main.async {
                    if let url = url {
                        NSWorkspace.shared.open(url)
                        return
                    }
                    fallbackOpenInFinder(vault: vault)
                }
            }
        } else {
            fallbackOpenInFinder(vault: vault)
        }
    }
    
    private func fallbackOpenInFinder(vault: VaultInfo) {
        let cloudStorageURL = CloudDrivePaths.cloudStorageDirectory
        
        let candidates = [
            cloudStorageURL.appendingPathComponent("CloudDrive-\(vault.name)"),
            cloudStorageURL.appendingPathComponent("CloudDrive-\(vault.id)"),
            cloudStorageURL.appendingPathComponent(vault.name)
        ]
        
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate.path) {
                NSWorkspace.shared.open(candidate)
                return
            }
        }
        
        // Dynamic search in ~/Library/CloudStorage for any matching vault directory
        if let contents = try? FileManager.default.contentsOfDirectory(at: cloudStorageURL, includingPropertiesForKeys: nil) {
            if let matched = contents.first(where: {
                $0.lastPathComponent.localizedCaseInsensitiveContains(vault.name) ||
                $0.lastPathComponent.localizedCaseInsensitiveContains(vault.id)
            }) {
                NSWorkspace.shared.open(matched)
                return
            }
        }
        
        NSWorkspace.shared.open(cloudStorageURL)
    }
}
