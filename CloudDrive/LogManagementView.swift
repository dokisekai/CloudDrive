//
//  LogManagementView.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  日志管理视图
//

import SwiftUI
import CloudDriveCore

struct LogManagementView: View {
    @StateObject private var windowController = LogWindowController.shared
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("日志管理")
                    .font(.headline)
                    .fontWeight(.bold)
                
                Spacer()
                
                Button("全部关闭") {
                    closeAllWindows()
                }
                .disabled(windowController.openWindows.isEmpty)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            if windowController.openWindows.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 80))
                        .foregroundColor(.secondary)
                    
                    Text("没有打开的日志窗口")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    
                    Text("点击下方按钮打开日志窗口")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 280, maximum: 350), spacing: 20)
                    ], spacing: 20) {
                        ForEach(windowController.openWindows) { windowInfo in
                            LogModuleCard(windowInfo: windowInfo)
                        }
                    }
                    .padding(20)
                }
            }
            
            Divider()
            
            VStack(spacing: 16) {
                Text("打开日志窗口")
                    .font(.headline)
                
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 16)
                ], spacing: 16) {
                    ForEach(Logger.Category.allCases, id: \.self) { category in
                        LogModuleButton(category: category)
                    }
                }
                .padding(.horizontal)
            }
            .padding(20)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }
    
    private func closeAllWindows() {
        windowController.openWindows.forEach { windowInfo in
            NSApp.windows.first { $0.title == windowInfo.title }?.close()
        }
    }
}

struct LogModuleCard: View {
    let windowInfo: LogWindowInfo
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: windowInfo.category.icon)
                    .font(.system(size: 32))
                    .foregroundColor(windowInfo.category.color)
                
                Spacer()
                
                Button(action: {}) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭窗口")
            }
            
            Text(windowInfo.title)
                .font(.headline)
                .fontWeight(.semibold)
            
            HStack {
                Label("已打开", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
                
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }
}

struct LogModuleButton: View {
    let category: Logger.Category
    
    var body: some View {
        Button(action: {
            LogWindowController.shared.openLogWindow(for: category)
        }) {
            VStack(spacing: 12) {
                Image(systemName: category.icon)
                    .font(.system(size: 36))
                    .foregroundColor(category.color)
                
                Text(category.displayName)
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Text("打开日志窗口")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(category.color.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
