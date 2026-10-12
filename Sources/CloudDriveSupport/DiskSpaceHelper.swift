//
//  DiskSpaceHelper.swift
//  CloudDriveSupport
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  Mac 本地磁盘容量与可用空间探测工具 (标准 Apple APFS / FileProvider 卷探测)
//

import Foundation
import Darwin

/// 磁盘空间信息快照
public struct DiskSpaceInfo: Sendable {
    public let totalBytes: Int64
    public let availableBytes: Int64
    
    public init(totalBytes: Int64, availableBytes: Int64) {
        self.totalBytes = max(0, totalBytes)
        self.availableBytes = max(0, availableBytes)
    }
    
    /// 剩余可用百分比 (0.0 ~ 100.0)
    public var freePercentage: Double {
        guard totalBytes > 0 else { return 0 }
        return min(100.0, max(0.0, (Double(availableBytes) / Double(totalBytes)) * 100.0))
    }
    
    /// 人类可读格式的可用容量 (例如 "156.4 GB")
    public var formattedAvailable: String {
        ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
    }
    
    /// 人类可读格式的总容量 (例如 "494.4 GB")
    public var formattedTotal: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
    
    /// 综合摘要 (例如 "剩余 156.4 GB / 494.4 GB (31.6%)")
    public var summary: String {
        String(format: "剩余 %@ / %@ (%.1f%%)", formattedAvailable, formattedTotal, freePercentage)
    }
}

/// 磁盘空间探测辅助单例
public enum DiskSpaceHelper {
    /// 获取指定目录所在本地物理卷的容量与可用空间
    public static func currentDiskSpace(at url: URL = CloudDrivePaths.sharedDirectory) -> DiskSpaceInfo {
        let targetURL = FileManager.default.fileExists(atPath: url.path) ? url : URL(fileURLWithPath: "/")
        
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        
        if let values = try? targetURL.resourceValues(forKeys: keys),
           let total = values.volumeTotalCapacity {
            let available = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
            return DiskSpaceInfo(totalBytes: Int64(total), availableBytes: available)
        }
        
        // APFS / POSIX statvfs 回退探测
        var stat = statvfs()
        if statvfs(targetURL.path, &stat) == 0 {
            let total = Int64(stat.f_blocks) * Int64(stat.f_frsize)
            let available = Int64(stat.f_bavail) * Int64(stat.f_frsize)
            return DiskSpaceInfo(totalBytes: total, availableBytes: available)
        }
        
        return DiskSpaceInfo(totalBytes: 0, availableBytes: 0)
    }
}
