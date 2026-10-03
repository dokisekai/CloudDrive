//
//  LogManagementView.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  日志管理视图 - 统一现代 macOS 模块面板 (支持多语言)
//

import SwiftUI
import AppKit
import CloudDriveCore

struct LogManagementView: View {
    var showsHeader: Bool = true
    @StateObject private var windowController = LogWindowController.shared
    @ObservedObject private var localization = LocalizationManager.shared
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶栏操作区
            HStack {
                if showsHeader {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("log_mgmt_title"))
                            .font(.headline)
                        Text(L("log_mgmt_subtitle"))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text(L("log_mgmt_subtitle"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button {
                    openLogDirectory()
                } label: {
                    Label(L("log_btn_browse_dir"), systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                if !windowController.openWindows.isEmpty {
                    Button(role: .destructive) {
                        closeAllWindows()
                    } label: {
                        Label(L("log_btn_close_all"), systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // 模块卡片列表
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(Logger.Category.allCases, id: \.self) { category in
                        LogCategoryCard(
                            category: category,
                            isOpen: isWindowOpen(for: category),
                            onToggle: {
                                toggleLogWindow(for: category)
                            }
                        )
                    }
                }
                .padding(16)
            }
        }
    }
    
    private func isWindowOpen(for category: Logger.Category) -> Bool {
        windowController.openWindows.contains { $0.category == category }
    }
    
    private func toggleLogWindow(for category: Logger.Category) {
        if isWindowOpen(for: category) {
            let title = "\(categoryDisplayName(category)) \(L("tab_logs"))"
            let window = NSApp.windows.first { $0.title == title || $0.frameAutosaveName == "LogWindow-\(category.rawValue)" }
            window?.close()
        } else {
            windowController.openLogWindow(for: category)
        }
    }
    
    private func closeAllWindows() {
        windowController.openWindows.forEach { windowInfo in
            NSApp.windows.first { $0.frameAutosaveName == "LogWindow-\(windowInfo.category.rawValue)" || $0.title == windowInfo.title }?.close()
        }
    }
    
    private func openLogDirectory() {
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".CloudDrive")
            .appendingPathComponent("Logs")
        NSWorkspace.shared.open(logDir)
    }
    
    private func categoryDisplayName(_ cat: Logger.Category) -> String {
        switch cat {
        case .system: return L("cat_system")
        case .fileOps: return L("cat_file_ops")
        case .webdav: return L("cat_webdav")
        case .cache: return L("cat_cache")
        case .database: return L("cat_database")
        case .sync: return L("cat_sync")
        }
    }
}

struct LogCategoryCard: View {
    let category: Logger.Category
    let isOpen: Bool
    let onToggle: () -> Void
    
    @ObservedObject private var localization = LocalizationManager.shared
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 12) {
            // 图标
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(category.color.opacity(0.15))
                    .frame(width: 40, height: 40)
                
                Image(systemName: category.icon)
                    .font(.system(size: 20))
                    .foregroundColor(category.color)
            }
            
            // 说明
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(categoryDisplayName(category))
                        .font(.system(size: 13, weight: .semibold))
                    
                    if isOpen {
                        Text(L("log_status_running"))
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .foregroundColor(.green)
                            .cornerRadius(4)
                    }
                }
                
                Text(categoryDescription(category))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer(minLength: 4)
            
            // 操作按钮
            if isOpen {
                Button(L("log_btn_close"), action: onToggle)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button(L("log_btn_open"), action: onToggle)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isHovered ? category.color.opacity(0.4) : Color(NSColor.separatorColor).opacity(0.3), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isHovered ? 0.05 : 0.01), radius: 3, x: 0, y: 1)
        .onHover { hovering in
            isHovered = hovering
        }
    }
    
    private func categoryDisplayName(_ cat: Logger.Category) -> String {
        switch cat {
        case .system: return L("cat_system")
        case .fileOps: return L("cat_file_ops")
        case .webdav: return L("cat_webdav")
        case .cache: return L("cat_cache")
        case .database: return L("cat_database")
        case .sync: return L("cat_sync")
        }
    }
    
    private func categoryDescription(_ cat: Logger.Category) -> String {
        switch cat {
        case .system: return L("cat_system_desc")
        case .fileOps: return L("cat_file_ops_desc")
        case .webdav: return L("cat_webdav_desc")
        case .cache: return L("cat_cache_desc")
        case .database: return L("cat_database_desc")
        case .sync: return L("cat_sync_desc")
        }
    }
}

extension Logger.Category {
    var icon: String {
        switch self {
        case .system:
            return "gearshape.2.fill"
        case .fileOps:
            return "doc.fill"
        case .webdav:
            return "externaldrive.fill"
        case .cache:
            return "memorychip.fill"
        case .database:
            return "cylinder.fill"
        case .sync:
            return "arrow.triangle.2.circlepath"
        }
    }
    
    var color: Color {
        switch self {
        case .system:
            return .blue
        case .fileOps:
            return .green
        case .webdav:
            return .orange
        case .cache:
            return .purple
        case .database:
            return .red
        case .sync:
            return .cyan
        }
    }
}
