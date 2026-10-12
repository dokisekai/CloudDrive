//
//  BaiduPanFormView.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  百度网盘开放平台配置表单组件（含设备码 OAuth 授权流）
//

import SwiftUI
import AppKit
import CloudDriveStorage
import CloudDriveContracts

struct BaiduPanFormView: View {
    @Binding var appID: String
    @Binding var appKey: String
    @Binding var clientSecret: String
    @Binding var appFolderName: String
    @Binding var rootPath: String
    @Binding var refreshToken: String
    @Binding var accessToken: String
    let isConnecting: Bool
    
    @State private var showSecret = false
    @State private var showAdvanced = false
    
    // OAuth 授权状态
    @State private var isAuthorizing = false
    @State private var authErrorMessage: String?
    @State private var deviceCodeResponse: BaiduPanDeviceCodeResponse?
    @State private var pollingTask: Task<Void, Never>?
    @State private var copiedNotice = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // AppKey (Client ID)
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .foregroundColor(.blue)
                    .frame(width: 16)
                TextField("AppKey (Client ID)", text: $appKey)
                    .disabled(isConnecting || isAuthorizing)
                    .help("百度网盘开发者控制台分配的 AppKey")
            }
            
            // App Secret (Client Secret)
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundColor(.secondary)
                    .frame(width: 16)
                if showSecret {
                    TextField("SecretKey (Client Secret)", text: $clientSecret)
                        .disabled(isConnecting || isAuthorizing)
                } else {
                    SecureField("SecretKey (Client Secret)", text: $clientSecret)
                        .disabled(isConnecting || isAuthorizing)
                }
                
                Button {
                    showSecret.toggle()
                } label: {
                    Image(systemName: showSecret ? "eye.slash" : "eye")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            // App Folder Name (围栏目录名)
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.gearshape")
                    .foregroundColor(.secondary)
                    .frame(width: 16)
                TextField("应用目录名 (如 CloudDrive)", text: $appFolderName)
                    .disabled(isConnecting || isAuthorizing)
                    .help("对应网盘 /apps/{应用名} 目录")
            }
            
            Divider()
                .padding(.vertical, 2)
            
            // MARK: - OAuth 授权绑定区块
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .foregroundColor(refreshToken.isEmpty ? .secondary : .green)
                    Text("账号授权绑定")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    if !refreshToken.isEmpty && !isAuthorizing {
                        Button("重新授权") {
                            startDeviceCodeAuthorization()
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .foregroundColor(.blue)
                    }
                }
                
                if !refreshToken.isEmpty && !isAuthorizing {
                    if BaiduPanTokenStore().needsReauth(vaultID: "default") {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("百度网盘凭据已失效，请点击右上角「重新授权」")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.08))
                        .cornerRadius(6)
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("百度网盘账号已成功授权（凭据已安全落库，支持静默续期）")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(8)
                        .background(Color.green.opacity(0.08))
                        .cornerRadius(6)
                    }
                } else if isAuthorizing {
                    VStack(alignment: .leading, spacing: 8) {
                        if let code = deviceCodeResponse {
                            Text("1. 请点击下方按钮打开百度网盘授权页；\n2. 登录并输入授权码确认绑定：")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            HStack(spacing: 12) {
                                Text(code.user_code)
                                    .font(.system(.title3, design: .monospaced))
                                    .fontWeight(.bold)
                                    .foregroundColor(.blue)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Color.blue.opacity(0.1))
                                    .cornerRadius(6)
                                
                                Button {
                                    copyCodeAndOpenWeb(code)
                                } label: {
                                    Label(copiedNotice ? "已复制并打开" : "复制授权码并打开授权页", systemImage: "arrow.up.right.square")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                            
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 16, height: 16)
                                Text("正在等待授权确认...")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("取消") {
                                    cancelAuthorization()
                                }
                                .font(.caption)
                                .buttonStyle(.borderless)
                                .foregroundColor(.red)
                            }
                            .padding(.top, 4)
                        } else {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 16, height: 16)
                                Text("正在向百度网盘请求设备授权码...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("取消") {
                                    cancelAuthorization()
                                }
                                .font(.caption)
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.04))
                    .cornerRadius(8)
                } else {
                    Button {
                        startDeviceCodeAuthorization()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "qrcode")
                            Text("网页 / 扫码授权百度网盘账号")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(appKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              isConnecting)
                }
                
                if let err = authErrorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            
            // MARK: - 高级选项折叠
            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "number")
                            .foregroundColor(.secondary)
                            .frame(width: 16)
                        TextField("AppID (可选，下载时由开放平台识别)", text: $appID)
                            .disabled(isConnecting || isAuthorizing)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundColor(.secondary)
                            .frame(width: 16)
                        TextField("手动指定 Token (可选 Access Token 或 Refresh Token)", text: $refreshToken)
                            .disabled(isConnecting || isAuthorizing)
                    }
                    Text("💡 推荐优先点击上方「网页 / 扫码授权」获取长期有效凭据；若在开放平台控制台直接获取了 Access Token (以 127. 或 24. 开头) 也可直接粘贴于此。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            } label: {
                Text("高级选项")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // 提示说明
            Text("💡 百度网盘所有加密数据将隔离在「我的应用数据/\(appFolderName.isEmpty ? "CloudDrive" : appFolderName)」目录下。")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - OAuth 授权逻辑
    
    private func startDeviceCodeAuthorization() {
        authErrorMessage = nil
        isAuthorizing = true
        deviceCodeResponse = nil
        copiedNotice = false
        
        let config = BaiduPanStorageConfig(
            appID: appID.trimmingCharacters(in: .whitespacesAndNewlines),
            appKey: appKey.trimmingCharacters(in: .whitespacesAndNewlines),
            clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines),
            appFolderName: appFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "CloudDrive" : appFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        
        let client = BaiduPanAPIClient(config: config, vaultID: "default")
        
        pollingTask?.cancel()
        pollingTask = Task {
            do {
                let codeResp = try await client.requestDeviceCode()
                await MainActor.run {
                    self.deviceCodeResponse = codeResp
                }
                
                let interval = max(3, codeResp.interval)
                let deadline = Date().addingTimeInterval(TimeInterval(codeResp.expires_in))
                
                while Date() < deadline {
                    try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                    if Task.isCancelled { return }
                    
                    do {
                        let tokenResp = try await client.exchangeDeviceCode(codeResp.device_code)
                        if let error = tokenResp.error, !error.isEmpty {
                            if error == "authorization_pending" || error == "slow_down" {
                                continue
                            } else {
                                await MainActor.run {
                                    self.authErrorMessage = "授权未完成: \(tokenResp.error_description ?? error)"
                                    self.isAuthorizing = false
                                }
                                return
                            }
                        }
                        
                        // 授权成功：写库并记录 accessToken 与 refreshToken
                        try client.persistAuthorized(tokenResp)
                        await MainActor.run {
                            self.refreshToken = tokenResp.refresh_token ?? ""
                            self.accessToken = tokenResp.access_token ?? ""
                            self.isAuthorizing = false
                            self.authErrorMessage = nil
                            self.deviceCodeResponse = nil
                        }
                        return
                    } catch {
                        // 继续等待下一轮轮询
                        continue
                    }
                }
                
                await MainActor.run {
                    self.authErrorMessage = "授权超时，请重试"
                    self.isAuthorizing = false
                    self.deviceCodeResponse = nil
                }
            } catch {
                await MainActor.run {
                    self.authErrorMessage = "请求授权码失败: \(error.localizedDescription)"
                    self.isAuthorizing = false
                    self.deviceCodeResponse = nil
                }
            }
        }
    }
    
    private func copyCodeAndOpenWeb(_ code: BaiduPanDeviceCodeResponse) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code.user_code, forType: .string)
        copiedNotice = true
        if let url = URL(string: code.verification_url) {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func cancelAuthorization() {
        pollingTask?.cancel()
        pollingTask = nil
        isAuthorizing = false
        deviceCodeResponse = nil
        authErrorMessage = nil
    }
}
