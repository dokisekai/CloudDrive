//
//  S3FormView.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  S3 / 对象存储配置表单组件
//

import SwiftUI

enum S3ProviderPreset: String, CaseIterable, Identifiable {
    case custom = "custom"
    case aws = "aws"
    case r2 = "r2"
    case wasabi = "wasabi"
    case aliyun = "aliyun"
    case tencent = "tencent"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .custom: return L("s3_preset_custom")
        case .aws: return "Amazon AWS S3"
        case .r2: return "Cloudflare R2"
        case .wasabi: return "Wasabi"
        case .aliyun: return L("s3_preset_aliyun")
        case .tencent: return L("s3_preset_tencent")
        }
    }
    
    func apply(
        endpoint: inout String,
        region: inout String,
        usePathStyle: inout Bool
    ) {
        switch self {
        case .custom:
            endpoint = "http://127.0.0.1:9000"
            region = "us-east-1"
            usePathStyle = true
        case .aws:
            endpoint = "https://s3.amazonaws.com"
            region = "us-east-1"
            usePathStyle = false
        case .r2:
            endpoint = "https://<account_id>.r2.cloudflarestorage.com"
            region = "auto"
            usePathStyle = true
        case .wasabi:
            endpoint = "https://s3.wasabisys.com"
            region = "us-east-1"
            usePathStyle = false
        case .aliyun:
            endpoint = "https://oss-cn-hangzhou.aliyuncs.com"
            region = "cn-hangzhou"
            usePathStyle = false
        case .tencent:
            endpoint = "https://cos.ap-guangzhou.myqcloud.com"
            region = "ap-guangzhou"
            usePathStyle = false
        }
    }
}

struct S3FormView: View {
    @Binding var preset: S3ProviderPreset
    @Binding var endpoint: String
    @Binding var region: String
    @Binding var bucket: String
    @Binding var accessKey: String
    @Binding var secretKey: String
    @Binding var rootPrefix: String
    @Binding var usePathStyle: Bool
    let isConnecting: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 预设选择
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundColor(.orange)
                    .frame(width: 16)
                Picker(L("field_s3_preset"), selection: $preset) {
                    ForEach(S3ProviderPreset.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .disabled(isConnecting)
                .onChange(of: preset) { newPreset in
                    newPreset.apply(endpoint: &endpoint, region: &region, usePathStyle: &usePathStyle)
                }
            }
            
            // 服务端点 Endpoint
            HStack(spacing: 8) {
                Image(systemName: "network")
                    .foregroundColor(.orange)
                    .frame(width: 16)
                TextField(L("field_s3_endpoint"), text: $endpoint)
                    .disabled(isConnecting)
                    .help("e.g. https://s3.amazonaws.com or http://127.0.0.1:9000")
            }
            
            // 区域 Region + 存储桶 Bucket
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .foregroundColor(.secondary)
                    .frame(width: 16)
                TextField(L("field_s3_region"), text: $region)
                    .disabled(isConnecting)
                    .help("e.g. us-east-1, auto, cn-north-1")
                
                Divider().frame(height: 18)
                
                Image(systemName: "archivebox.fill")
                    .foregroundColor(.secondary)
                    .frame(width: 16)
                TextField(L("field_s3_bucket"), text: $bucket)
                    .disabled(isConnecting)
            }
            
            // Access Key + Secret Key
            HStack(spacing: 8) {
                Image(systemName: "person.badge.key.fill")
                    .foregroundColor(.secondary)
                    .frame(width: 16)
                TextField(L("field_s3_access_key"), text: $accessKey)
                    .disabled(isConnecting)
            }
            
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .foregroundColor(.secondary)
                    .frame(width: 16)
                SecureField(L("field_s3_secret_key"), text: $secretKey)
                    .disabled(isConnecting)
            }
            
            // 前缀与路径模式
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundColor(.secondary)
                    .frame(width: 16)
                TextField(L("field_s3_prefix"), text: $rootPrefix)
                    .disabled(isConnecting)
            }
            
            Toggle(L("field_s3_path_style"), isOn: $usePathStyle)
                .disabled(isConnecting)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
