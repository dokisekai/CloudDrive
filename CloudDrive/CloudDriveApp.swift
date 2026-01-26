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
    
    init() {
        // 添加 print 调试
        print("========================================")
        print("CloudDrive App init() 被调用")
        print("========================================")
        
        // 强制初始化 Logger
        let _ = Logger.shared
        print("Logger.shared 已初始化")
        
        // 初始化新的日志系统
        logInfo(.system, "CloudDrive 应用启动")
        print("logInfo 已调用")
        
        if let logPath = Logger.shared.getLogFilePath(for: .system) {
            print("系统日志路径: \(logPath)")
            logInfo(.system, "日志目录: \(logPath)")
        } else {
            print("无法获取日志路径")
        }
        
        print("========================================")
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onAppear {
                    logInfo(.system, "ContentView 已显示")
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("打开日志目录") {
                    let logDir = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent(".CloudDrive")
                        .appendingPathComponent("Logs")
                    NSWorkspace.shared.open(logDir)
                }
                Button("打开系统日志") {
                    if let logPath = Logger.shared.getLogFilePath(for: .system) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
                    }
                }
                Button("打开文件操作日志") {
                    if let logPath = Logger.shared.getLogFilePath(for: .fileOps) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
                    }
                }
            }
        }
    }
}