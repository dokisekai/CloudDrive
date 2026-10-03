//
//  Pan123DatabaseStore.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  123云盘持久化数据库支持：Token 30天持久化、每分钟/每天请求频率限制与每日流量统计
//

import Foundation
import CloudDriveContracts
import CloudDriveSupport
import SQLite3
import CloudDrivePersistence

/// 123云盘今日使用统计模型
public final class Pan123DatabaseStore: @unchecked Sendable {
    public static let shared = Pan123DatabaseStore()
    
    public let dbURL: URL
    let conn: SQLiteConnection
    let lock = NSLock()
    
    let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()
    
    let minuteFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df
    }()
    
    public init(dbURL: URL = CloudDrivePaths.sharedDirectory.appendingPathComponent("pan123.db")) {
        self.dbURL = dbURL
        self.conn = SQLiteConnection(dbPath: dbURL)
        ensureSchema()
    }
    
    // MARK: - Schema Management
    
    private func ensureSchema() {
        let createTokenTable = """
        CREATE TABLE IF NOT EXISTS pan123_tokens (
            client_id TEXT PRIMARY KEY,
            access_token TEXT NOT NULL,
            expired_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """
        try? conn.execute(sql: createTokenTable)
        
        let createStatsTable = """
        CREATE TABLE IF NOT EXISTS pan123_request_stats (
            client_id TEXT NOT NULL,
            period_type TEXT NOT NULL,
            period_key TEXT NOT NULL,
            request_count INTEGER NOT NULL DEFAULT 0,
            download_bytes INTEGER NOT NULL DEFAULT 0,
            updated_at REAL NOT NULL,
            PRIMARY KEY (client_id, period_type, period_key)
        );
        """
        try? conn.execute(sql: createStatsTable)
        
        let createIndex = """
        CREATE INDEX IF NOT EXISTS idx_pan123_stats ON pan123_request_stats(client_id, period_type, period_key);
        """
        try? conn.execute(sql: createIndex)
    }
}
