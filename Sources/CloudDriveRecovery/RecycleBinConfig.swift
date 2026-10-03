//
//  RecycleBinConfig.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  回收站配置管理（以加密库为单位，配置持久化存放于该加密库独立的 vfs.db 数据库中，默认关闭 false）
//

import Foundation
import CloudDrivePersistence

public enum RecycleBinConfig {
    private static let appGroupSuiteName = "group.net.aabg.CloudDrive"
    private static let perVaultPrefix = "recycle_bin_enabled_"
    private static let retentionDaysKey = "recycle_bin_retention_days"
    private static let localSnapshotKey = "recycle_bin_local_snapshot_enabled"
    
    private static var userDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupSuiteName) ?? UserDefaults.standard
    }
    
    /// 获取指定加密库的回收站是否开启（以该加密库 vfs.db 数据库为准，默认关闭 false）
    public static func isEnabled(for vaultId: String? = nil) -> Bool {
        guard let vaultId = vaultId, !vaultId.isEmpty else {
            return false // 默认关闭
        }
        
        // 1. 优先读取该加密库本地 SQLite 数据库中的专属配置表
        let db = VFSDatabase(vaultId: vaultId)
        if FileManager.default.fileExists(atPath: db.dbPath.path) {
            return db.isRecycleBinEnabled()
        }
        
        // 2. 检查跨进程 IPC 缓存（若数据库文件尚未生成）
        let key = perVaultPrefix + vaultId
        if let cached = userDefaults.object(forKey: key) as? Bool {
            return cached
        }
        
        return false // 默认关闭
    }
    
    /// 设置指定加密库的回收站开关（持久化存入加密库专属数据库 vfs.db 中）
    public static func setEnabled(_ enabled: Bool, for vaultId: String? = nil) {
        guard let vaultId = vaultId, !vaultId.isEmpty else { return }
        
        // 1. 存入该加密库自己的数据库
        let db = VFSDatabase(vaultId: vaultId)
        try? db.setRecycleBinEnabled(enabled)
        
        // 2. 同步写入 AppGroup 共享缓存以便扩展与宿主即时感知
        let key = perVaultPrefix + vaultId
        userDefaults.set(enabled, forKey: key)
    }
    
    /// 检查指定存储库是否有专属设置
    public static func hasVaultOverride(for vaultId: String) -> Bool {
        return true
    }
    
    /// 获取指定存储库的设置
    public static func vaultSpecificSetting(for vaultId: String) -> Bool? {
        return isEnabled(for: vaultId)
    }
    
    /// 重置存储库设置（重置为默认关闭状态）
    public static func resetToGlobal(for vaultId: String) {
        setEnabled(false, for: vaultId)
    }
    
    /// 回收站保留天数 (0 代表永久保留，默认 30 天)
    public static var retentionDays: Int {
        get {
            let defaults = userDefaults
            if defaults.object(forKey: retentionDaysKey) != nil {
                return defaults.integer(forKey: retentionDaysKey)
            }
            return 30
        }
        set {
            userDefaults.set(newValue, forKey: retentionDaysKey)
        }
    }
    
    /// 是否保留本地缓存快照以支持即时还原（默认开启）
    public static var isLocalSnapshotEnabled: Bool {
        get {
            let defaults = userDefaults
            if defaults.object(forKey: localSnapshotKey) != nil {
                return defaults.bool(forKey: localSnapshotKey)
            }
            return true
        }
        set {
            userDefaults.set(newValue, forKey: localSnapshotKey)
        }
    }
}
