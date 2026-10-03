//
//  VaultListView.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  保险库卡片列表/网格视图 (支持自适应流式网格排版)
//

import SwiftUI
import AppKit
import CloudDriveCore

struct VaultListView: View {
    let vaults: [VaultInfo]
    @ObservedObject var appState: AppState
    @ObservedObject private var localization = LocalizationManager.shared
    let onRequestDelete: (VaultInfo) -> Void
    var onEdit: ((VaultInfo) -> Void)? = nil
    var onChangePassword: ((VaultInfo) -> Void)? = nil
    
    // 自适应网格布局：最小 340pt，自动适配宽屏与分栏
    private let columns = [
        GridItem(.adaptive(minimum: 340, maximum: 540), spacing: 16)
    ]
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(vaults) { vault in
                    VaultCardView(
                        vaultId: vault.id,
                        appState: appState,
                        onRequestDelete: { onRequestDelete(vault) },
                        onEdit: { v in onEdit?(v) },
                        onChangePassword: { v in onChangePassword?(v) }
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}
