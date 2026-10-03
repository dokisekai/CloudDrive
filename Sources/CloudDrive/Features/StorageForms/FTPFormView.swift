//
//  FTPFormView.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  FTP / FTPS 配置表单组件（带字段图标与 TLS 视觉区分）
//

import SwiftUI

struct FTPFormView: View {
    @Binding var host: String
    @Binding var port: Int
    @Binding var username: String
    @Binding var password: String
    @Binding var path: String
    @Binding var useTLS: Bool
    let isConnecting: Bool
    
    var body: some View {
        // 主机 + 端口
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
                .foregroundColor(.cyan)
                .frame(width: 16)
            TextField(L("field_ftp_host"), text: $host)
                .disabled(isConnecting)
                .help("e.g. ftp.example.com or 192.168.1.50")
            
            Divider().frame(height: 18)
            
            Text(L("field_ftp_port"))
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("21", value: $port, formatter: NumberFormatter())
                .frame(width: 52)
                .multilineTextAlignment(.trailing)
                .disabled(isConnecting)
        }
        
        // 用户名 + 密码
        HStack(spacing: 8) {
            Image(systemName: "person.fill")
                .foregroundColor(.secondary)
                .frame(width: 16)
            TextField(L("field_username"), text: $username)
                .disabled(isConnecting)
        }
        
        HStack(spacing: 8) {
            Image(systemName: "key.fill")
                .foregroundColor(.secondary)
                .frame(width: 16)
            SecureField(L("field_password"), text: $password)
                .disabled(isConnecting)
        }
        
        // 远端路径
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundColor(.secondary)
                .frame(width: 16)
            TextField(L("field_ftp_path"), text: $path)
                .disabled(isConnecting)
        }
        
        // FTPS 加密开关
        HStack(spacing: 8) {
            Image(systemName: useTLS ? "lock.shield.fill" : "lock.open.fill")
                .foregroundColor(useTLS ? .green : .secondary)
                .frame(width: 16)
            Toggle(L("field_ftp_tls"), isOn: $useTLS)
                .disabled(isConnecting)
            
            if useTLS {
                Text(L("field_ftp_tls_on_hint"))
                    .font(.caption2)
                    .foregroundColor(.green)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: useTLS)
    }
}
