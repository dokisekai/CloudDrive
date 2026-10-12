//
//  AppSettings.swift
//  CloudDriveSupport
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  软件级别全局配置中心（持久化存放于 App Group 共享存储区中，全 App 及扩展统一读写）
//

import Foundation
import Combine

/// 软件级别全局配置中心
/// 缓存管理模式
public enum CacheManagementMode: String, CaseIterable, Identifiable, Sendable {
    case smart = "smart"    // 智能模式 (基于设备物理磁盘剩余空间百分比，iCloud 风格)
    case fixed = "fixed"    // 固定配额模式 (经典固定大小限制)
    
    public var id: String { rawValue }
}

/// 软件级别全局配置中心
public final class AppSettings: ObservableObject, @unchecked Sendable {
    public static let shared = AppSettings()
    
    private let appGroupSuite = "group.net.aabg.CloudDrive"
    private let userDefaults: UserDefaults
    private let lock = NSRecursiveLock()
    
    // MARK: - 存储键名常量
    public enum Keys {
        public static let showMenuBarIcon = "app_show_menu_bar_icon"
        public static let showMainWindowOnLaunch = "app_show_main_window_on_launch"
        public static let autoMountOnLaunch = "app_auto_mount_on_launch"
        public static let confirmBeforeUnmount = "app_confirm_before_unmount"
        public static let showNotifications = "app_show_notifications"
        public static let autoLock = "app_auto_lock"
        public static let autoLockTimeout = "app_auto_lock_timeout"
        public static let maxCacheQuotaBytes = "clouddrive_max_cache_size"
        public static let cacheManagementMode = "app_cache_management_mode"
        public static let smartFreeSpacePercentage = "app_smart_free_space_percentage"
        public static let enableBuiltinIgnoreRules = "app_enable_builtin_ignore_rules"
        public static let globalIgnorePatterns = "app_global_ignore_patterns"
    }
    
    // MARK: - 响应式配置属性
    
    /// 菜单栏常驻图标显示
    @Published public var showMenuBarIcon: Bool {
        didSet { save(key: Keys.showMenuBarIcon, value: showMenuBarIcon) }
    }
    
    /// 启动时展示主窗口
    @Published public var showMainWindowOnLaunch: Bool {
        didSet { save(key: Keys.showMainWindowOnLaunch, value: showMainWindowOnLaunch) }
    }
    
    /// 启动时自动挂载各存储库（全局总闸）
    @Published public var autoMountOnLaunch: Bool {
        didSet { save(key: Keys.autoMountOnLaunch, value: autoMountOnLaunch) }
    }
    
    /// 卸载或断开连接前弹出确认
    @Published public var confirmBeforeUnmount: Bool {
        didSet { save(key: Keys.confirmBeforeUnmount, value: confirmBeforeUnmount) }
    }
    
    /// 启用系统级通知
    @Published public var showNotifications: Bool {
        didSet { save(key: Keys.showNotifications, value: showNotifications) }
    }
    
    /// 闲置超时自动锁定
    @Published public var autoLock: Bool {
        didSet { save(key: Keys.autoLock, value: autoLock) }
    }
    
    /// 自动锁定超时时间（分钟）
    @Published public var autoLockTimeout: Double {
        didSet { save(key: Keys.autoLockTimeout, value: autoLockTimeout) }
    }
    
    /// 全局最大缓存配额（GB）
    @Published public var maxCacheQuotaGB: Int {
        didSet {
            let bytes = Int64(maxCacheQuotaGB) * 1024 * 1024 * 1024
            save(key: Keys.maxCacheQuotaBytes, value: bytes)
        }
    }
    
    /// 缓存管理模式（默认智能自适应模式）
    @Published public var cacheManagementMode: CacheManagementMode {
        didSet { save(key: Keys.cacheManagementMode, value: cacheManagementMode.rawValue) }
    }
    
    /// 智能模式下保持的 Mac 最小剩余可用空间百分比（默认 15%）
    @Published public var smartFreeSpacePercentage: Int {
        didSet { save(key: Keys.smartFreeSpacePercentage, value: smartFreeSpacePercentage) }
    }
    
    /// 启用软件内置忽略规则（如 .DS_Store, Thumbs.db 等）
    @Published public var enableBuiltinIgnoreRules: Bool {
        didSet { save(key: Keys.enableBuiltinIgnoreRules, value: enableBuiltinIgnoreRules) }
    }
    
    /// 软件全局通用忽略规则列表（对所有加密库生效）
    @Published public var globalIgnorePatterns: [String] {
        didSet { save(key: Keys.globalIgnorePatterns, value: globalIgnorePatterns) }
    }
    
    // MARK: - 初始化与加载
    
    public init() {
        let defaults = UserDefaults(suiteName: "group.net.aabg.CloudDrive") ?? UserDefaults.standard
        self.userDefaults = defaults
        
        // 初始值读取（兼容旧版或赋予标准默认值）
        self.showMenuBarIcon = defaults.object(forKey: Keys.showMenuBarIcon) as? Bool
            ?? defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true
        
        self.showMainWindowOnLaunch = defaults.object(forKey: Keys.showMainWindowOnLaunch) as? Bool
            ?? defaults.object(forKey: "showMainWindowOnLaunch") as? Bool ?? true
        
        self.autoMountOnLaunch = defaults.object(forKey: Keys.autoMountOnLaunch) as? Bool
            ?? defaults.object(forKey: "autoMountOnLaunch") as? Bool ?? true
        
        self.confirmBeforeUnmount = defaults.object(forKey: Keys.confirmBeforeUnmount) as? Bool
            ?? defaults.object(forKey: "confirmBeforeUnmount") as? Bool ?? true
        
        self.showNotifications = defaults.object(forKey: Keys.showNotifications) as? Bool
            ?? defaults.object(forKey: "showNotifications") as? Bool ?? true
        
        self.autoLock = defaults.object(forKey: Keys.autoLock) as? Bool
            ?? defaults.object(forKey: "autoLock") as? Bool ?? false
        
        self.autoLockTimeout = defaults.object(forKey: Keys.autoLockTimeout) as? Double
            ?? defaults.object(forKey: "autoLockTimeout") as? Double ?? 15.0
        
        if let bytes = defaults.object(forKey: Keys.maxCacheQuotaBytes) as? Int64, bytes > 0 {
            self.maxCacheQuotaGB = max(1, Int(bytes / (1024 * 1024 * 1024)))
        } else {
            self.maxCacheQuotaGB = 10
        }
        
        let modeRaw = defaults.string(forKey: Keys.cacheManagementMode) ?? CacheManagementMode.smart.rawValue
        self.cacheManagementMode = CacheManagementMode(rawValue: modeRaw) ?? .smart
        self.smartFreeSpacePercentage = defaults.object(forKey: Keys.smartFreeSpacePercentage) as? Int ?? 15
        
        self.enableBuiltinIgnoreRules = defaults.object(forKey: Keys.enableBuiltinIgnoreRules) as? Bool ?? true
        
        self.globalIgnorePatterns = defaults.stringArray(forKey: Keys.globalIgnorePatterns) ?? [
            ".DS_Store",
            "Thumbs.db",
            "desktop.ini",
            "._*",
            ".Spotlight-V100",
            ".Trashes"
        ]
    }
    
    // MARK: - 持久化存储辅助
    
    private func save<T>(key: String, value: T) {
        lock.lock()
        defer { lock.unlock() }
        userDefaults.set(value, forKey: key)
        userDefaults.synchronize()
    }
    
    /// 重置所有软件设置到出厂默认值
    public func resetToDefaults() {
        lock.lock()
        defer { lock.unlock() }
        showMenuBarIcon = true
        showMainWindowOnLaunch = true
        autoMountOnLaunch = true
        confirmBeforeUnmount = true
        showNotifications = true
        autoLock = false
        autoLockTimeout = 15.0
        maxCacheQuotaGB = 10
        cacheManagementMode = .smart
        smartFreeSpacePercentage = 15
        enableBuiltinIgnoreRules = true
        globalIgnorePatterns = [
            ".DS_Store",
            "Thumbs.db",
            "desktop.ini",
            "._*",
            ".Spotlight-V100",
            ".Trashes"
        ]
    }
}
