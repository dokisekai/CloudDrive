//
//  CreateVaultView.swift
//  CloudDriveApp
//
//  创建保险库视图
//

import SwiftUI
import CloudDriveCore

struct CreateVaultView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    
    // WebDAV 配置 - 默认值
    @State private var webdavURL = ""
    @State private var webdavUsername = ""
    @State private var webdavPassword = ""
    
    @State private var isConnecting = false
    @State private var isTesting = false
    @State private var testSuccess = false
    @State private var errorMessage: String?
    @State private var testMessage: String?
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("连接 WebDAV 存储")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("取消") { dismiss() }
                    .disabled(isConnecting)
            }
            .padding()
            
            Divider()
            
            // 表单内容
            Form {
                // WebDAV 配置
                Section("WebDAV 服务器") {
                    TextField("WebDAV URL", text: $webdavURL)
                        .disabled(isConnecting)
                        .help("例如: https://dav.example.com")
                    TextField("用户名", text: $webdavUsername)
                        .disabled(isConnecting)
                    SecureField("密码", text: $webdavPassword)
                        .disabled(isConnecting)
                    
                    Text("直接映射 WebDAV 存储，不创建新目录")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    // 测试连接按钮
                    HStack {
                        Button(action: testConnection) {
                            HStack(spacing: 6) {
                                if isTesting {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .frame(width: 16, height: 16)
                                } else if testSuccess {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                } else {
                                    Image(systemName: "network")
                                }
                                Text(isTesting ? "测试中..." : (testSuccess ? "连接成功" : "测试连接"))
                            }
                        }
                        .disabled(isTesting || !isWebDAVConfigValid)
                        .buttonStyle(.bordered)
                        
                        if let message = testMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundColor(testSuccess ? .green : .secondary)
                        }
                    }
                }
                
                // 错误信息
                if let error = errorMessage {
                    Section {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("连接失败")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.red)
                                Text(error)
                                    .font(.caption2)
                                    .foregroundColor(.red)
                            }
                        }
                        .padding(8)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                    }
                }
            }
            .formStyle(.grouped)
            
            Divider()
            
            // 底部按钮
            HStack {
                Spacer()
                
                Button(isConnecting ? "连接中..." : "连接") {
                    connectWebDAV()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isWebDAVConfigValid || isConnecting || !testSuccess)
                .help(testSuccess ? "点击连接 WebDAV 存储" : "请先测试 WebDAV 连接")
            }
            .padding()
        }
        .frame(width: 550, height: 500)
    }
    
    // WebDAV 配置验证
    private var isWebDAVConfigValid: Bool {
        return !webdavURL.isEmpty &&
               !webdavUsername.isEmpty &&
               !webdavPassword.isEmpty
    }
    
    // 测试 WebDAV 连接
    private func testConnection() {
        isTesting = true
        testSuccess = false
        testMessage = nil
        errorMessage = nil
        
        Task {
            do {
                guard let url = URL(string: webdavURL) else {
                    await MainActor.run {
                        testMessage = "无效的 URL"
                        isTesting = false
                    }
                    return
                }
                
                // 配置 WebDAV 客户端
                let client = WebDAVClient.shared
                client.configure(baseURL: url, username: webdavUsername, password: webdavPassword)
                
                // 测试连接
                let success = try await client.testConnection()
                
                await MainActor.run {
                    testSuccess = success
                    testMessage = success ? "连接成功！" : "连接失败"
                    isTesting = false
                }
                
            } catch {
                await MainActor.run {
                    testSuccess = false
                    let errorDesc = error.localizedDescription
                    testMessage = "连接失败"
                    errorMessage = errorDesc
                    isTesting = false
                    
                    print("❌ WebDAV 连接测试失败: \(errorDesc)")
                }
            }
        }
    }
    
    // 连接 WebDAV 存储
    private func connectWebDAV() {
        isConnecting = true
        errorMessage = nil
        
        Task {
            do {
                guard let url = URL(string: webdavURL) else {
                    await MainActor.run {
                        errorMessage = "无效的 URL"
                        isConnecting = false
                    }
                    return
                }
                
                // 直接连接并映射 WebDAV 存储（不创建任何目录）
                try await appState.connectWebDAVStorage(
                    name: "WebDAV 存储",
                    webdavURL: webdavURL,
                    username: webdavUsername,
                    webdavPassword: webdavPassword
                )
                
                await MainActor.run {
                    dismiss()
                }
                
            } catch {
                await MainActor.run {
                    let errorDesc = error.localizedDescription
                    errorMessage = errorDesc
                    isConnecting = false
                    
                    print("❌ 连接 WebDAV 存储失败: \(errorDesc)")
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct CreateVaultView_Previews: PreviewProvider {
    static var previews: some View {
        CreateVaultView()
            .environmentObject(AppState())
    }
}
#endif