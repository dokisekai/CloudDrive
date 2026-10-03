//
//  CloudDriveApp.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//

import SwiftUI
import CloudDriveCore

@main
struct CloudDriveApp: App {
    @StateObject private var appState = AppState()
    @ObservedObject private var localization = LocalizationManager.shared
    @StateObject private var statusBarManager = StatusBarManager.shared
    
    init() {
        _ = Logger.shared
        logInfo(.system, "CloudDrive application launched")
        if let logPath = Logger.shared.getLogFilePath(for: .system) {
            logInfo(.system, "System log directory: \(logPath)")
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(localization)
                .environment(\.locale, localization.currentEffectiveLanguage == .chinese ? Locale(identifier: "zh-Hans") : Locale(identifier: "en"))
                .onAppear {
                    logInfo(.system, "ContentView appeared")
                    statusBarManager.configure(with: appState)
                    
                    if !AppSettings.shared.showMainWindowOnLaunch {
                        DispatchQueue.main.async {
                            NSApplication.shared.windows.first?.orderOut(nil)
                        }
                    }
                    
                    Task {
                        guard AppSettings.shared.autoMountOnLaunch else {
                            logInfo(.system, "Auto-mount on launch is disabled globally in AppSettings")
                            statusBarManager.updateStatusIcon()
                            return
                        }
                        for vault in appState.vaults {
                            if vault.isAutoMount {
                                if appState.currentVault?.id == vault.id && vault.isMounted {
                                    continue
                                }
                                logInfo(.system, "Auto-mounting vault: \(vault.name)")
                                do {
                                    try await appState.remountVault(vault)
                                    logSuccess(.system, "Auto-mounted vault successfully: \(vault.name)")
                                } catch {
                                    logWarning(.system, "Failed to auto-mount vault \(vault.name): \(error.localizedDescription)")
                                }
                            }
                        }
                        statusBarManager.updateStatusIcon()
                    }
                }
                .onChange(of: appState.vaults) { _ in
                    statusBarManager.updateStatusIcon()
                }
        }
        .defaultSize(width: 920, height: 600)
        .commands {
            // 偏好设置快捷键与应用菜单项
            CommandGroup(after: .appInfo) {
                Button(L("toolbar_settings_tooltip") + "...") {
                    NotificationCenter.default.post(name: Notification.Name("OpenSettingsModal"), object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            
            // 文件菜单项：新建、打开、直连
            CommandGroup(replacing: .newItem) {
                Button(L("toolbar_new_encrypted_vault") + "...") {
                    NotificationCenter.default.post(name: Notification.Name("OpenCreateVaultModal"), object: VaultCreationMode.createEncrypted)
                }
                .keyboardShortcut("n", modifiers: .command)
                
                Button(L("toolbar_open_existing_vault") + "...") {
                    NotificationCenter.default.post(name: Notification.Name("OpenCreateVaultModal"), object: VaultCreationMode.openExisting)
                }
                .keyboardShortcut("o", modifiers: .command)
                
                Button(L("toolbar_direct_storage") + "...") {
                    NotificationCenter.default.post(name: Notification.Name("OpenCreateVaultModal"), object: VaultCreationMode.directWebDAV)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            
            // 视图菜单项：刷新
            CommandGroup(after: .toolbar) {
                Button(L("toolbar_refresh_tooltip")) {
                    NotificationCenter.default.post(name: Notification.Name("TriggerRefreshAllVaults"), object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            
            // 帮助与诊断菜单项
            CommandGroup(replacing: .help) {
                Button(L("menu_open_log_directory")) {
                    let logDir = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent(".CloudDrive")
                        .appendingPathComponent("Logs")
                    NSWorkspace.shared.open(logDir)
                }
                Button(L("menu_open_system_log")) {
                    if let logPath = Logger.shared.getLogFilePath(for: .system) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
                    }
                }
                Button(L("menu_open_file_ops_log")) {
                    if let logPath = Logger.shared.getLogFilePath(for: .fileOps) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
                    }
                }
            }
        }
    }
}