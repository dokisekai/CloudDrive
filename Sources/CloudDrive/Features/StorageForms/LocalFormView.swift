//
//  LocalFormView.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  本地文件夹存储配置表单 (支持通过 NSOpenPanel 选择本地、外接磁盘或 U 盘目录并生成安全书签)
//

import SwiftUI
import AppKit
import CloudDriveCore

struct LocalFormView: View {
    @Binding var path: String
    @Binding var bookmarkData: Data?
    let isConnecting: Bool
    var onPathSelected: ((String) -> Void)? = nil
    
    @ObservedObject private var localization = LocalizationManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill.badge.gearshape")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("field_local_path"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(path.isEmpty ? L("field_local_browse_help") : path)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(path.isEmpty ? .secondary.opacity(0.8) : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                
                Spacer()
                
                Button(action: selectLocalFolder) {
                    Label(L("field_local_browse"), systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
                .disabled(isConnecting)
            }
            .padding(10)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 1)
            )
            
            Text(L("field_local_browse_help"))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
    
    private func selectLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L("open")
        panel.message = L("local_folder_picker_prompt")
        
        if panel.runModal() == .OK, let selectedURL = panel.url {
            self.path = selectedURL.path
            do {
                self.bookmarkData = try selectedURL.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            } catch {
                logError(.system, "Failed to create security bookmark for local URL: \(error)")
            }
            onPathSelected?(selectedURL.path)
        }
    }
}
