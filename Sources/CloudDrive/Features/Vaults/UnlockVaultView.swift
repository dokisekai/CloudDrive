//
//  UnlockVaultView.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  解锁加密保险库弹窗视图（同时支持存储密码与加密密码重新输入）
//

import SwiftUI
import CloudDriveCore

struct UnlockVaultView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    @ObservedObject private var localization = LocalizationManager.shared
    
    let vault: VaultInfo
    
    @State private var storagePassword = ""
    @State private var vaultPassword = ""
    @State private var isUnlocking = false
    @State private var errorMessage: String?
    @State private var showStoragePassword = false
    @State private var showVaultPassword = false
    
    /// 是否需要输入存储密码（Keychain 中缺失时为 true）
    private var needsStoragePassword: Bool {
        // 非本地保险库且 Keychain 中没有存储密码
        !vault.isLocal && CredentialStore.shared.getStoragePassword(for: vault.id) == nil
    }
    
    /// 是否需要输入加密密码
    private var needsVaultPassword: Bool {
        vault.isEncrypted && CredentialStore.shared.getVaultPassword(for: vault.id) == nil
    }
    
    /// 是否可以提交
    private var canSubmit: Bool {
        if needsStoragePassword && storagePassword.isEmpty { return false }
        if needsVaultPassword && vaultPassword.isEmpty { return false }
        // 至少要有一个密码字段存在
        if !needsStoragePassword && !needsVaultPassword {
            // 即使 Keychain 都有，加密库仍需要用户输入加密密码来验证
            if vault.isEncrypted { return !vaultPassword.isEmpty }
            return !storagePassword.isEmpty
        }
        return true
    }
    
    var body: some View {
        VStack(spacing: 22) {
            // 图标与标题
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(
                            LinearGradient(
                                colors: [Color.orange.opacity(0.18), Color.orange.opacity(0.06)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 64, height: 64)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                        )
                        .shadow(color: Color.orange.opacity(0.12), radius: 8, x: 0, y: 3)
                    
                    Image(systemName: vault.isEncrypted ? "lock.shield.fill" : "key.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(.orange)
                }
                .padding(.top, 6)
                
                VStack(spacing: 4) {
                    Text(L("unlock_title"))
                        .font(.system(size: 17, weight: .bold))
                    
                    HStack(spacing: 6) {
                        Image(systemName: vault.storageType.iconName)
                            .font(.system(size: 10))
                            .foregroundColor(vault.storageType.themeColor)
                        Text(vault.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
                }
            }
            .padding(.horizontal)
            
            VStack(alignment: .leading, spacing: 14) {
                // 存储密码（WebDAV / S3 / SMB / FTP）
                if needsStoragePassword || !vault.isEncrypted {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(storagePasswordLabel)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        HStack(spacing: 8) {
                            Image(systemName: "key.fill")
                                .foregroundColor(.secondary)
                                .font(.system(size: 12))
                            if showStoragePassword {
                                TextField(L("unlock_storage_password_placeholder"), text: $storagePassword)
                                    .textFieldStyle(.plain)
                                    .disabled(isUnlocking)
                                    .onSubmit { submitIfReady() }
                            } else {
                                SecureField(L("unlock_storage_password_placeholder"), text: $storagePassword)
                                    .textFieldStyle(.plain)
                                    .disabled(isUnlocking)
                                    .onSubmit { submitIfReady() }
                            }
                            Button {
                                showStoragePassword.toggle()
                            } label: {
                                Image(systemName: showStoragePassword ? "eye.slash" : "eye")
                                    .foregroundColor(.secondary)
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 1)
                        )
                    }
                }
                
                // 加密密码（仅加密库）
                if vault.isEncrypted {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L("unlock_vault_password_label"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        HStack(spacing: 8) {
                            Image(systemName: "lock.fill")
                                .foregroundColor(.secondary)
                                .font(.system(size: 12))
                            if showVaultPassword {
                                TextField(L("unlock_password_placeholder"), text: $vaultPassword)
                                    .textFieldStyle(.plain)
                                    .disabled(isUnlocking)
                                    .onSubmit { submitIfReady() }
                            } else {
                                SecureField(L("unlock_password_placeholder"), text: $vaultPassword)
                                    .textFieldStyle(.plain)
                                    .disabled(isUnlocking)
                                    .onSubmit { submitIfReady() }
                            }
                            Button {
                                showVaultPassword.toggle()
                            } label: {
                                Image(systemName: showVaultPassword ? "eye.slash" : "eye")
                                    .foregroundColor(.secondary)
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 1)
                        )
                    }
                }
                
                if let error = errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 12))
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                            .lineLimit(2)
                    }
                }
            }
            .padding(.horizontal, 28)
            
            HStack(spacing: 12) {
                Button(L("cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isUnlocking)
                
                Button {
                    unlock()
                } label: {
                    if isUnlocking {
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                            Text(L("unlock_btn_unlocking"))
                        }
                        .frame(minWidth: 80)
                    } else {
                        Text(L("unlock_btn_unlock"))
                            .frame(minWidth: 80)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit || isUnlocking)
            }
            .padding(.bottom, 6)
        }
        .frame(width: 440)
        .padding(20)
    }
    
    private var storagePasswordLabel: String {
        if let config = vault.storageConfig {
            return L("unlock_storage_password_label", config.type.localizedName)
        }
        return L("unlock_storage_password_label", "WebDAV")
    }
    
    private func submitIfReady() {
        if canSubmit && !isUnlocking {
            unlock()
        }
    }
    
    private func unlock() {
        isUnlocking = true
        errorMessage = nil
        
        Task {
            do {
                // 如果用户输入了存储密码，先保存到 Keychain
                let effectiveStoragePassword = storagePassword.isEmpty ? nil : storagePassword
                if let sp = effectiveStoragePassword {
                    appState.saveCredentialsToAppGroup(
                        vaultId: vault.id,
                        webdavPassword: sp,
                        vaultPassword: nil
                    )
                }
                
                // 对加密库使用加密密码解锁；对非加密库使用存储密码挂载
                let unlockPassword = vault.isEncrypted ? vaultPassword : storagePassword
                try await appState.unlockVault(vaultId: vault.id, password: unlockPassword)
                
                await MainActor.run {
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isUnlocking = false
                }
            }
        }
    }
}
