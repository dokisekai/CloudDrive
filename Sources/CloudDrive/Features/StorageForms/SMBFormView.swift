//
//  SMBFormView.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  SMB / Windows 共享配置表单组件（带字段图标与共享路径预览）
//

import SwiftUI

struct SMBFormView: View {
    @Binding var host: String
    @Binding var port: Int
    @Binding var share: String
    @Binding var path: String
    @Binding var username: String
    @Binding var password: String
    @Binding var domain: String
    let isConnecting: Bool
    
    /// 实时预览拼接后的 UNC 路径
    private var previewPath: String {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = share.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.isEmpty && s.isEmpty { return "" }
        let base = "smb://\(h)/\(s)"
        return p.isEmpty || p == "/" ? base : "\(base)\(p.hasPrefix("/") ? p : "/\(p)")"
    }
    
    var body: some View {
        // 主机 + 端口
        HStack(spacing: 8) {
            Image(systemName: "network")
                .foregroundColor(.blue)
                .frame(width: 16)
            TextField(L("field_smb_host"), text: $host)
                .disabled(isConnecting)
                .help("e.g. 192.168.1.100 or nas.local")
            
            Divider().frame(height: 18)
            
            Text(L("field_smb_port"))
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("445", value: $port, formatter: NumberFormatter())
                .frame(width: 52)
                .multilineTextAlignment(.trailing)
                .disabled(isConnecting)
        }
        
        // 共享名 + 子路径
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.fill")
                .foregroundColor(.blue)
                .frame(width: 16)
            TextField(L("field_smb_share"), text: $share)
                .disabled(isConnecting)
                .help("e.g. Data or Media")
            
            Text("/")
                .foregroundColor(.secondary)
            
            TextField(L("field_smb_subpath"), text: $path)
                .disabled(isConnecting)
                .help("e.g. / or /documents")
                .frame(maxWidth: 120)
        }
        
        // 路径预览
        if !previewPath.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(previewPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.leading, 24)
        }
        
        // 用户名
        HStack(spacing: 8) {
            Image(systemName: "person.fill")
                .foregroundColor(.secondary)
                .frame(width: 16)
            TextField(L("field_username"), text: $username)
                .disabled(isConnecting)
        }
        
        // 密码
        HStack(spacing: 8) {
            Image(systemName: "key.fill")
                .foregroundColor(.secondary)
                .frame(width: 16)
            SecureField(L("field_password"), text: $password)
                .disabled(isConnecting)
        }
        
        // 域名（可选）
        HStack(spacing: 8) {
            Image(systemName: "building.2.fill")
                .foregroundColor(.secondary)
                .frame(width: 16)
            TextField(L("field_smb_domain"), text: $domain)
                .disabled(isConnecting)
                .help("e.g. WORKGROUP (optional)")
        }
    }
}
