//
//  SettingsView.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  设置视图
//

import SwiftUI
import CloudDriveCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("通用", systemImage: "gear")
                }
            
            CacheSettingsView()
                .tabItem {
                    Label("缓存", systemImage: "externaldrive")
                }
            
            LogManagementView()
                .tabItem {
                    Label("日志", systemImage: "doc.text")
                }
            
            AboutView()
                .tabItem {
                    Label("关于", systemImage: "info.circle")
                }
        }
        .frame(width: 600, height: 450)
    }
}

struct GeneralSettingsView: View {
    @AppStorage("autoLock") private var autoLock = true
    @AppStorage("autoLockTimeout") private var autoLockTimeout = 15.0
    
    var body: some View {
        Form {
            Section("安全") {
                Toggle("自动锁定保险库", isOn: $autoLock)
                
                if autoLock {
                    HStack {
                        Text("超时时间:")
                        Slider(value: $autoLockTimeout, in: 5...60, step: 5)
                        Text("\(Int(autoLockTimeout)) 分钟")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct CacheSettingsView: View {
    @State private var cacheSize: String = "计算中..."
    
    var body: some View {
        Form {
            Section("缓存信息") {
                HStack {
                    Text("当前缓存大小:")
                    Spacer()
                    Text(cacheSize)
                        .foregroundColor(.secondary)
                }
                
                Button("清空缓存") {
                    clearCache()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            updateCacheSize()
        }
    }
    
    private func updateCacheSize() {
        let size = CacheManager.shared.currentCacheSize()
        cacheSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
    
    private func clearCache() {
        try? CacheManager.shared.clearAllCache()
        updateCacheSize()
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 60))
                .foregroundColor(.blue)
            
            Text("CloudDrive")
                .font(.title)
                .fontWeight(.bold)
            
            Text("版本 1.0.0")
                .foregroundColor(.secondary)
            
            Text("端到端加密的云存储解决方案")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Divider()
                .padding(.vertical)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("特性:")
                    .font(.headline)
                
                Label("AES-256-GCM 加密", systemImage: "lock.fill")
                Label("WebDAV 存储", systemImage: "externaldrive.fill")
                Label("macOS 系统集成", systemImage: "apple.logo")
                Label("本地智能缓存", systemImage: "memorychip.fill")
            }
            .font(.caption)
            
            Spacer()
        }
        .padding()
    }
}