//
//  ChangeVaultPasswordSheet.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  修改加密保险库主密码弹窗 (安全重新加密云端 masterkey 文件并更新本地钥匙串)
//

import SwiftUI
import CloudDriveCore

struct ChangeVaultPasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    
    let vault: VaultInfo
    
    @State private var oldPassword: String = ""
    @State private var newPassword: String = ""
    @State private var confirmPassword: String = ""
    
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String? = nil
    @State private var showingSuccessAlert: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶栏
            HStack(spacing: 12) {
                Image(systemName: "key.horizontal.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("change_pwd_title"))
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(vault.name)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            
            Divider()
            
            // 内容区域
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // 原理解释卡片
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(.accentColor)
                            .font(.title3)
                        Text(L("change_pwd_subtitle"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08))
                    .cornerRadius(8)
                    
                    // 表单输入
                    VStack(alignment: .leading, spacing: 14) {
                        // 1. 原密码
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("change_pwd_current"))
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                            SecureField(L("change_pwd_current_placeholder"), text: $oldPassword)
                                .textFieldStyle(.roundedBorder)
                                .disabled(isSubmitting)
                        }
                        
                        Divider().padding(.vertical, 2)
                        
                        // 2. 新密码
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("change_pwd_new"))
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                            SecureField(L("change_pwd_new_placeholder"), text: $newPassword)
                                .textFieldStyle(.roundedBorder)
                                .disabled(isSubmitting)
                        }
                        
                        // 3. 确认新密码
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("change_pwd_confirm"))
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                            SecureField(L("change_pwd_confirm_placeholder"), text: $confirmPassword)
                                .textFieldStyle(.roundedBorder)
                                .disabled(isSubmitting)
                        }
                    }
                    .padding(16)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(10)
                    
                    // 安全提示说明
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lightbulb.fill")
                            .foregroundColor(.orange)
                            .font(.body)
                        Text(L("change_pwd_notice"))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.07))
                    .cornerRadius(8)
                    
                    // 错误信息提示
                    if let err = errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(err)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .padding(24)
            }
            
            Divider()
            
            // 底部按钮栏
            HStack {
                Button(L("cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSubmitting)
                
                Spacer()
                
                Button {
                    performPasswordChange()
                } label: {
                    if isSubmitting {
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                            Text(L("change_pwd_submitting"))
                        }
                    } else {
                        Text(L("change_pwd_submit"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting || oldPassword.isEmpty || newPassword.isEmpty || confirmPassword.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(minWidth: 460, maxWidth: 520, minHeight: 440, maxHeight: 520)
        .alert(L("change_pwd_success"), isPresented: $showingSuccessAlert) {
            Button(L("ok")) {
                dismiss()
            }
        }
    }
    
    private func performPasswordChange() {
        let cleanOld = oldPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNew = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanConfirm = confirmPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !cleanOld.isEmpty else {
            errorMessage = L("change_pwd_current_placeholder")
            return
        }
        guard cleanNew.count >= 8 else {
            errorMessage = L("change_pwd_err_length")
            return
        }
        guard cleanNew == cleanConfirm else {
            errorMessage = L("change_pwd_err_mismatch")
            return
        }
        guard cleanNew != cleanOld else {
            errorMessage = L("change_pwd_err_same")
            return
        }
        
        isSubmitting = true
        errorMessage = nil
        
        Task {
            do {
                try await appState.changeVaultPassword(vault: vault, oldPassword: cleanOld, newPassword: cleanNew)
                await MainActor.run {
                    isSubmitting = false
                    showingSuccessAlert = true
                }
            } catch let vfsError as VFSError {
                await MainActor.run {
                    isSubmitting = false
                    if case .invalidPassword = vfsError {
                        errorMessage = L("change_pwd_err_wrong_old")
                    } else {
                        errorMessage = vfsError.localizedDescription
                    }
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
