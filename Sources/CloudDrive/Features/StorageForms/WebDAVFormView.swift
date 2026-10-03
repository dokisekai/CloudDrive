//
//  WebDAVFormView.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  WebDAV 配置表单组件（带实时 URL 格式校验与字段图标）
//

import SwiftUI

struct WebDAVFormView: View {
    @Binding var url: String
    @Binding var username: String
    @Binding var password: String
    let isConnecting: Bool
    
    /// URL 格式校验
    private var isURLValid: Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true } // 空时不报错
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
    }
    
    var body: some View {
        // WebDAV 地址
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "network")
                    .foregroundColor(.teal)
                    .frame(width: 16)
                TextField(L("field_webdav_url"), text: $url)
                    .disabled(isConnecting)
                    .help("e.g. https://pan.example.com/webdav")
                
                if !url.isEmpty {
                    Image(systemName: isURLValid ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundColor(isURLValid ? .green : .orange)
                        .font(.system(size: 13))
                        .transition(.opacity)
                }
            }
            
            if !isURLValid {
                Text(L("webdav_url_hint"))
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .padding(.leading, 24)
            }
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
    }
}
