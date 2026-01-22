//
//  StatusBarManager.swift
//  CloudDrive
//
//  状态栏图标管理
//

import SwiftUI
import AppKit

class StatusBarManager: ObservableObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    
    @Published var isVisible = false
    
    init() {
        // 创建状态栏图标
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        // 配置图标
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: "CloudDrive")
            button.target = self
            button.action = #selector(togglePopover)
        }
        
        // 创建弹出视图
        popover = NSPopover()
        popover?.behavior = .transient
        popover?.contentSize = NSSize(width: 300, height: 200)
        
        // 配置弹出内容
        let contentView = StatusBarPopoverView()
        let hostingController = NSHostingController(rootView: contentView)
        popover?.contentViewController = hostingController
        
        // 注册应用间通信
        registerForAppCommunication()
    }
    
    @objc private func togglePopover() {
        if let button = statusItem?.button, let popover = popover {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }
    
    private func registerForAppCommunication() {
        // 注册分布式通知，用于接收来自帮助应用的消息
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.aabg.CloudDrive.HelpMessage"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleHelpMessage(notification)
        }
        
        // 注册本地通知，用于应用内部通信
        NotificationCenter.default.addObserver(
            forName: Notification.Name("com.aabg.CloudDrive.StatusUpdate"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleStatusUpdate(notification)
        }
    }
    
    private func handleHelpMessage(_ notification: Notification) {
        if let userInfo = notification.userInfo, let message = userInfo["message"] as? String {
            print("收到帮助消息: \(message)")
            // 处理来自帮助应用的消息
            // 例如：打开特定设置页面，显示帮助文档等
        }
    }
    
    private func handleStatusUpdate(_ notification: Notification) {
        // 处理应用内部的状态更新
        if let userInfo = notification.userInfo, let status = userInfo["status"] as? String {
            print("收到状态更新: \(status)")
            // 可以根据状态更新状态栏图标
        }
    }
    
    func showStatusBar() {
        isVisible = true
        // 可以在这里添加更多显示逻辑
    }
    
    func hideStatusBar() {
        isVisible = false
        // 可以在这里添加更多隐藏逻辑
    }
    
    // 发送消息到帮助应用
    func sendMessageToHelpApp(_ message: String) {
        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.aabg.CloudDrive.AppMessage"),
            object: Bundle.main.bundleIdentifier,
            userInfo: ["message": message]
        )
    }
}

// 状态栏弹出视图
struct StatusBarPopoverView: View {
    var body: some View {
        VStack(spacing: 20) {
            Text("CloudDrive")
                .font(.headline)
            
            Divider()
            
            Button("在 Finder 中打开") {
                // 实现打开 Finder 功能
                NSWorkspace.shared.openFile("/")
            }
            .buttonStyle(.bordered)
            
            Button("偏好设置") {
                // 实现打开偏好设置功能
            }
            .buttonStyle(.bordered)
            
            Button("退出") {
                // 实现退出应用功能
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}