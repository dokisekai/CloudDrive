import Foundation
import CloudDriveContracts
import CloudDriveSupport
import SQLite3
import CloudDrivePersistence

public struct Pan123UsageStats: Codable, Sendable {
    public let clientID: String
    public let date: String
    public let todayRequestCount: Int
    public let todayDownloadBytes: Int64
    public let currentMinuteRequestCount: Int
    public let maxDailyDownloadBytes: Int64
    
    public var remainingDailyDownloadBytes: Int64 {
        if maxDailyDownloadBytes <= 0 { return Int64.max }
        return max(0, maxDailyDownloadBytes - todayDownloadBytes)
    }
    
    public var formattedDownloadSize: String {
        ByteCountFormatter.string(fromByteCount: todayDownloadBytes, countStyle: .file)
    }
    
    public var formattedRemainingDownloadSize: String {
        if maxDailyDownloadBytes <= 0 { return "无限制" }
        return ByteCountFormatter.string(fromByteCount: remainingDailyDownloadBytes, countStyle: .file)
    }
}

/// 123云盘 SQLite 持久化存储与配额控制器
