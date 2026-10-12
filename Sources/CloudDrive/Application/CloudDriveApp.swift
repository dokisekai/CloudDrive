//
//  CloudDriveApp.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//

import SwiftUI
import CloudDriveCore
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("net.aabg.CloudDrive.userNotice"),
            object: nil,
            queue: .main
        ) { note in
            let title = note.userInfo?["title"] as? String ?? "CloudDrive"
            let message = note.userInfo?["message"] as? String ?? ""
            
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message
            content.sound = .default
            
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sender.activate(ignoringOtherApps: true)
        for window in sender.windows {
            if window.canBecomeMain || window.title.contains("CloudDrive") {
                window.makeKeyAndOrderFront(nil)
                return true
            }
        }
        return true
    }
}

@main
struct CloudDriveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
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
                    } else {
                        DispatchQueue.main.async {
                            NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }
                    
                    appState.autoMountEligibleVaults()
                    statusBarManager.updateStatusIcon()
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