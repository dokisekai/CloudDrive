import CloudDriveContracts
import CloudDriveSupport
import CloudDriveSecurity
//
//  FileProviderSync.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  File Provider 和主应用之间的同步机制
//

import Foundation
import FileProvider

/// File Provider 同步管理器
public class FileProviderSync {
    public static let shared = FileProviderSync()
    
    private let userDefaults = UserDefaults(suiteName: "group.net.aabg.CloudDrive")
    private let notificationCenter = CFNotificationCenterGetDistributedCenter()
    
    // 通知名称
    private let fileChangedNotification = "net.aabg.CloudDrive.fileChanged" as CFString
    private let vaultUnlockedNotification = "net.aabg.CloudDrive.vaultUnlocked" as CFString
    private let vaultLockedNotification = "net.aabg.CloudDrive.vaultLocked" as CFString
    
    private init() {
        setupNotificationObservers()
    }
    
    // MARK: - Notification Setup
    
    private func setupNotificationObservers() {
        // 监听文件变化通知
        CFNotificationCenterAddObserver(
            notificationCenter,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let sync = Unmanaged<FileProviderSync>.fromOpaque(observer).takeUnretainedValue()
                sync.handleFileChanged()
            },
            fileChangedNotification,
            nil,
            .deliverImmediately
        )
        
        // 监听保险库解锁通知
        CFNotificationCenterAddObserver(
            notificationCenter,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let sync = Unmanaged<FileProviderSync>.fromOpaque(observer).takeUnretainedValue()
                sync.handleVaultUnlocked()
            },
            vaultUnlockedNotification,
            nil,
            .deliverImmediately
        )
        
        // 监听保险库锁定通知
        CFNotificationCenterAddObserver(
            notificationCenter,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let sync = Unmanaged<FileProviderSync>.fromOpaque(observer).takeUnretainedValue()
                sync.handleVaultLocked()
            },
            vaultLockedNotification,
            nil,
            .deliverImmediately
        )
        
        NSLog("✅ FileProviderSync: Notification observers setup complete")
        print("FileProviderSync: Notification observers setup complete")
    }
    
    // MARK: - Notification Handlers
    
    private func handleFileChanged() {
        NSLog("📢 FileProviderSync: Received file changed notification")
        print("FileProviderSync: Received file changed notification")
        // 通知主应用刷新界面
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .fileProviderDidChangeFiles, object: nil)
        }
    }
    
    private func handleVaultUnlocked() {
        NSLog("📢 FileProviderSync: Received vault unlocked notification")
        print("FileProviderSync: Received vault unlocked notification")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .vaultDidUnlock, object: nil)
        }
    }
    
    private func handleVaultLocked() {
        NSLog("📢 FileProviderSync: Received vault locked notification")
        print("FileProviderSync: Received vault locked notification")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .vaultDidLock, object: nil)
        }
    }
    
    // MARK: - Send Notifications
    
    /// 通知文件已变化（从 File Provider Extension 调用）
    public func notifyFileChanged(vaultId: String, fileId: String) {
        NSLog("📤 FileProviderSync: Notifying file changed - vault: \(vaultId), file: \(fileId)")
        print("FileProviderSync: Notifying file changed - vault: \(vaultId), file: \(fileId)")
        
        // 保存到共享 UserDefaults
        userDefaults?.set(fileId, forKey: "lastChangedFile")
        userDefaults?.set(Date().timeIntervalSince1970, forKey: "lastChangeTime")
        
        // 发送 Darwin 通知（跨进程）
        CFNotificationCenterPostNotification(
            notificationCenter,
            CFNotificationName(fileChangedNotification),
            nil,
            nil,
            true
        )
        
        // 通知 File Provider Manager 刷新
        Task {
            await signalEnumeratorForVault(vaultId: vaultId)
        }
    }
    
    /// 通知保险库已解锁（从主应用调用）
    public func notifyVaultUnlocked(vaultId: String) {
        NSLog("📤 FileProviderSync: Notifying vault unlocked - vault: \(vaultId)")
        print("FileProviderSync: Notifying vault unlocked - vault: \(vaultId)")
        
        userDefaults?.set(vaultId, forKey: "unlockedVaultId")
        userDefaults?.set(Date().timeIntervalSince1970, forKey: "unlockTime")
        
        CFNotificationCenterPostNotification(
            notificationCenter,
            CFNotificationName(vaultUnlockedNotification),
            nil,
            nil,
            true
        )
        
        // 通知 File Provider 刷新
        Task {
            await signalEnumeratorForVault(vaultId: vaultId)
        }
    }
    
    /// 通知保险库已锁定（从主应用调用）
    public func notifyVaultLocked(vaultId: String) {
        NSLog("📤 FileProviderSync: Notifying vault locked - vault: \(vaultId)")
        print("FileProviderSync: Notifying vault locked - vault: \(vaultId)")
        
        userDefaults?.removeObject(forKey: "unlockedVaultId")
        
        CFNotificationCenterPostNotification(
            notificationCenter,
            CFNotificationName(vaultLockedNotification),
            nil,
            nil,
            true
        )
    }
    
    // MARK: - File Provider Manager Integration
    
    /// 通知 File Provider 刷新指定保险库
    private func signalEnumeratorForVault(vaultId: String) async {
        do {
            // 通知已注册的对应 File Provider domain 刷新
            let domains = try await NSFileProviderManager.domains()
            for domain in domains {
                let domainVaultId = domain.identifier.rawValue.hasPrefix("vault-") ? String(domain.identifier.rawValue.dropFirst(6)) : domain.identifier.rawValue
                if domainVaultId == vaultId {
                    await EnumeratorSignaler.shared.signal(for: domain, containerItemIdentifiers: [.rootContainer, .workingSet])
                    print("✅ FileProviderSync: Notified File Provider enumerator for vault: \(vaultId)")
                    break
                }
            }
        } catch {
            print("⚠️ FileProviderSync: Failed to signal File Provider enumerator: \(error)")
        }
    }
    
    /// 获取最后变化的文件信息
    public func getLastChangedFile() -> (fileId: String, timestamp: TimeInterval)? {
        guard let fileId = userDefaults?.string(forKey: "lastChangedFile"),
              let timestamp = userDefaults?.double(forKey: "lastChangeTime") else {
            return nil
        }
        return (fileId, timestamp)
    }
    
    /// 获取当前解锁的保险库ID
    public func getUnlockedVaultId() -> String? {
        return userDefaults?.string(forKey: "unlockedVaultId")
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    /// File Provider 文件变化通知
    static let fileProviderDidChangeFiles = Notification.Name("fileProviderDidChangeFiles")
    
    /// 保险库解锁通知
    static let vaultDidUnlock = Notification.Name("vaultDidUnlock")
    
    /// 保险库锁定通知
    static let vaultDidLock = Notification.Name("vaultDidLock")
}
