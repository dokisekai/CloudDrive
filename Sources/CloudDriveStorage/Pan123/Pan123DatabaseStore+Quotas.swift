import Foundation
import CloudDriveContracts
import CloudDriveSupport
import SQLite3
import CloudDrivePersistence

extension Pan123DatabaseStore {
    // MARK: - Rate Limiting & Quotas (每分钟/每天请求节流与流量追踪)
    
    /// 检查并获取请求执行槽位（若当前分钟超频则主动平滑等待，若今日超额则拦截）
    public func acquireRequestSlot(
        clientID: String,
        maxPerMinute: Int = 600,
        maxPerDay: Int = 100_000
    ) async throws {
        let cleanID = clientID.isEmpty ? "default" : clientID
        
        while true {
            let now = Date()
            let (dayKey, minuteKey, secondOfMinute) = getFormattedDates(for: now)
            
            // 1. 检查每日请求配额限制
            if maxPerDay > 0 {
                let todayCount = try getCount(for: cleanID, periodType: "day", periodKey: dayKey)
                if todayCount >= maxPerDay {
                    throw StorageError.serverError(
                        statusCode: 429,
                        message: "123云盘已达到今日请求次数上限 (\(todayCount)/\(maxPerDay))，已触发防护限制"
                    )
                }
            }
            
            // 2. 检查每分钟频率限制并平滑节流
            if maxPerMinute > 0 {
                let currentMinuteCount = try getCount(for: cleanID, periodType: "minute", periodKey: minuteKey)
                if currentMinuteCount >= maxPerMinute {
                    // 主动平滑休眠至下一分钟，避免向服务端直接发送导致 429 或拉黑
                    let waitSeconds = max(1, 60 - secondOfMinute)
                    try await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
                    continue
                }
            }
            
            // 3. 记录本次请求
            try incrementRequest(clientID: cleanID, dayKey: dayKey, minuteKey: minuteKey, now: now)
            break
        }
    }
    
    /// 记录今日下载产生的流量字节数
    public func recordDownloadBytes(clientID: String, bytes: Int64) throws {
        guard bytes > 0 else { return }
        let cleanID = clientID.isEmpty ? "default" : clientID
        let now = Date()
        let (dayKey, _, _) = getFormattedDates(for: now)
        
        lock.lock()
        defer { lock.unlock() }
        
        let db = try conn.getHandle()
        let sql = """
        INSERT INTO pan123_request_stats (client_id, period_type, period_key, request_count, download_bytes, updated_at)
        VALUES (?, 'day', ?, 0, ?, ?)
        ON CONFLICT(client_id, period_type, period_key) DO UPDATE SET
            download_bytes = download_bytes + excluded.download_bytes,
            updated_at = excluded.updated_at;
        """
        let stmt = try SQLiteStatement(db: db, sql: sql)
        stmt.bindText(cleanID, at: 1)
        stmt.bindText(dayKey, at: 2)
        stmt.bindInt64(bytes, at: 3)
        stmt.bindDouble(now.timeIntervalSince1970, at: 4)
        _ = stmt.step()
    }
    
    /// 获取当前账号的今日统计与流量配额情况
    public func getUsageStats(clientID: String, maxDailyDownloadBytes: Int64 = 1024 * 1024 * 1024) throws -> Pan123UsageStats {
        let cleanID = clientID.isEmpty ? "default" : clientID
        let now = Date()
        let (dayKey, minuteKey, _) = getFormattedDates(for: now)
        
        lock.lock()
        defer { lock.unlock() }
        
        let db = try conn.getHandle()
        
        // 查当天数据
        var dayRequests = 0
        var dayDownloads: Int64 = 0
        let daySQL = "SELECT request_count, download_bytes FROM pan123_request_stats WHERE client_id = ? AND period_type = 'day' AND period_key = ? LIMIT 1;"
        let dayStmt = try SQLiteStatement(db: db, sql: daySQL)
        dayStmt.bindText(cleanID, at: 1)
        dayStmt.bindText(dayKey, at: 2)
        if dayStmt.step() == SQLITE_ROW {
            dayRequests = Int(dayStmt.columnInt64(at: 0))
            dayDownloads = dayStmt.columnInt64(at: 1)
        }
        
        // 查当前分钟数据
        var minuteRequests = 0
        let minSQL = "SELECT request_count FROM pan123_request_stats WHERE client_id = ? AND period_type = 'minute' AND period_key = ? LIMIT 1;"
        let minStmt = try SQLiteStatement(db: db, sql: minSQL)
        minStmt.bindText(cleanID, at: 1)
        minStmt.bindText(minuteKey, at: 2)
        if minStmt.step() == SQLITE_ROW {
            minuteRequests = Int(minStmt.columnInt64(at: 0))
        }
        
        return Pan123UsageStats(
            clientID: cleanID,
            date: dayKey,
            todayRequestCount: dayRequests,
            todayDownloadBytes: dayDownloads,
            currentMinuteRequestCount: minuteRequests,
            maxDailyDownloadBytes: maxDailyDownloadBytes
        )
    }
    
    /// 清理 48 小时以前的过期分钟统计数据，保持数据库轻巧
    public func pruneOldStats() throws {
        lock.lock()
        defer { lock.unlock() }
        
        let db = try conn.getHandle()
        let cutoff = Date().addingTimeInterval(-48 * 3600).timeIntervalSince1970
        let sql = "DELETE FROM pan123_request_stats WHERE period_type = 'minute' AND updated_at < ?;"
        let stmt = try SQLiteStatement(db: db, sql: sql)
        stmt.bindDouble(cutoff, at: 1)
        _ = stmt.step()
    }
}
