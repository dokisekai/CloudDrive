//
//  EmptyVaultsView.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  无保险库时的空状态及欢迎引导卡片视图 (现代 macOS 原生质感重构)
//

import SwiftUI
import AppKit

struct EmptyVaultsView: View {
    @ObservedObject private var localization = LocalizationManager.shared
    var onCreateEncrypted: () -> Void
    var onOpenExisting: () -> Void
    var onDirectWebDAV: () -> Void
    
    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                Spacer(minLength: 24)
                
                // 顶部品牌与欢迎徽标
                VStack(spacing: 16) {
                    ZStack {
                        // 背景柔和光晕
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [Color.blue.opacity(0.22), Color.cyan.opacity(0.08), Color.clear],
                                    center: .center,
                                    startRadius: 10,
                                    endRadius: 70
                                )
                            )
                            .frame(width: 130, height: 130)
                        
                        RoundedRectangle(cornerRadius: 24)
                            .fill(
                                LinearGradient(
                                    colors: [Color(NSColor.controlBackgroundColor), Color(NSColor.windowBackgroundColor)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 84, height: 84)
                            .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 24)
                                    .stroke(
                                        LinearGradient(
                                            colors: [Color.white.opacity(0.4), Color.clear],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 1
                                    )
                            )
                        
                        Image(systemName: "externaldrive.badge.icloud")
                            .font(.system(size: 42, weight: .regular))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.blue, .cyan],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    
                    VStack(spacing: 8) {
                        Text(L("empty_welcome_title"))
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.primary)
                        
                        Text(L("empty_welcome_subtitle"))
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 480)
                    }
                }
                
                // 三大向导卡片
                HStack(spacing: 16) {
                    EmptyActionCard(
                        icon: "lock.shield.fill",
                        accentColor: .orange,
                        title: L("empty_card_new_title"),
                        desc: L("empty_card_new_desc"),
                        buttonTitle: L("empty_card_new_btn"),
                        isPrimary: true,
                        action: onCreateEncrypted
                    )
                    
                    EmptyActionCard(
                        icon: "lock.open.fill",
                        accentColor: .blue,
                        title: L("empty_card_open_title"),
                        desc: L("empty_card_open_desc"),
                        buttonTitle: L("empty_card_open_btn"),
                        isPrimary: false,
                        action: onOpenExisting
                    )
                    
                    EmptyActionCard(
                        icon: "arrow.triangle.2.circlepath",
                        accentColor: .teal,
                        title: L("empty_card_direct_title"),
                        desc: L("empty_card_direct_desc"),
                        buttonTitle: L("empty_card_direct_btn"),
                        isPrimary: false,
                        action: onDirectWebDAV
                    )
                }
                .frame(maxWidth: 720)
                
                // 底部特性说明条
                HStack(spacing: 24) {
                    EmptyFeaturePill(icon: "shield.lefthalf.filled", text: "Cryptomator 7/8 Spec")
                    EmptyFeaturePill(icon: "network", text: "WebDAV / S3 / SMB / FTP")
                    EmptyFeaturePill(icon: "bolt.fill", text: "macOS FileProvider")
                }
                .padding(.top, 8)
                
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, minHeight: 460)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - 引导操作卡片组件

struct EmptyActionCard: View {
    let icon: String
    let accentColor: Color
    let title: String
    let desc: String
    let buttonTitle: String
    let isPrimary: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 图标徽标
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                colors: [accentColor.opacity(0.18), accentColor.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(accentColor)
                }
                Spacer()
            }
            
            // 文本信息
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                
                Text(desc)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer(minLength: 10)
            
            // 按钮
            if isPrimary {
                Button(action: action) {
                    HStack(spacing: 6) {
                        Text(buttonTitle)
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            } else {
                Button(action: action) {
                    Text(buttonTitle)
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .padding(18)
        .frame(minHeight: 200)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isHovered ? accentColor.opacity(0.5) : Color(NSColor.separatorColor).opacity(0.35), lineWidth: isHovered ? 1.5 : 1)
        )
        .shadow(color: isHovered ? accentColor.opacity(0.12) : Color.black.opacity(0.03), radius: isHovered ? 8 : 2, x: 0, y: isHovered ? 3 : 1)
        .scaleEffect(isHovered ? 1.012 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - 特性说明小胶囊

struct EmptyFeaturePill: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(6)
    }
}
