//
//  Pan123FormView.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  123云盘开放平台配置表单组件
//

import SwiftUI

struct Pan123FormView: View {
    @Binding var clientID: String
    @Binding var clientSecret: String
    @Binding var accessToken: String
    @Binding var rootFolderID: Int64
    @Binding var rootPath: String
    let isConnecting: Bool
    
    @State private var showSecret = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Client ID
            HStack(spacing: 8) {
                Image(systemName: "person.badge.key.fill")
                    .foregroundColor(.indigo)
                    .frame(width: 16)
                TextField(L("field_pan123_client_id"), text: $clientID)
                    .disabled(isConnecting)
                    .help("123云盘开放平台分配的 ClientID")
            }
            
            // Client Secret
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .foregroundColor(.secondary)
                    .frame(width: 16)
                if showSecret {
                    TextField(L("field_pan123_client_secret"), text: $clientSecret)
                        .disabled(isConnecting)
                } else {
                    SecureField(L("field_pan123_client_secret"), text: $clientSecret)
                        .disabled(isConnecting)
                }
                
                Button {
                    showSecret.toggle()
                } label: {
                    Image(systemName: showSecret ? "eye.slash" : "eye")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            // Access Token (可选，可直接填入已申请到的 Token)
            HStack(spacing: 8) {
                Image(systemName: "ticket.fill")
                    .foregroundColor(.secondary)
                    .frame(width: 16)
                TextField(L("field_pan123_token"), text: $accessToken)
                    .disabled(isConnecting)
                    .help("若已直接拥有 AccessToken 可在此填入，无需填写 ClientSecret")
            }
            
            // 挂载根目录 ID + 逻辑路径
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.gearshape")
                    .foregroundColor(.secondary)
                    .frame(width: 16)
                Text(L("field_pan123_root_id"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("0", value: $rootFolderID, formatter: NumberFormatter())
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                    .disabled(isConnecting)
                    .help("0 代表网盘根目录，若挂载特定文件夹请填入其文件夹 ID")
                
                Divider().frame(height: 18)
                
                Image(systemName: "folder.fill")
                    .foregroundColor(.secondary)
                    .frame(width: 16)
                TextField("/", text: $rootPath)
                    .disabled(isConnecting)
            }
            
            // 底部提示
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundColor(.indigo)
                    .font(.caption2)
                Text(L("field_pan123_tip"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 2)
        }
    }
}
