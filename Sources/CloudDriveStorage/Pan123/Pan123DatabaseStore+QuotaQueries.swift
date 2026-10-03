import Foundation
import CloudDriveContracts
import CloudDriveSupport
import SQLite3
import CloudDrivePersistence

extension Pan123DatabaseStore {
    // MARK: - Internal Helpers
    
    func getFormattedDates(for date: Date) -> (day: String, minute: String, second: Int) {
        lock.lock()
        defer { lock.unlock() }
        let day = dayFormatter.string(from: date)
        let minute = minuteFormatter.string(from: date)
        let second = Calendar.current.component(.second, from: date)
        return (day, minute, second)
    }
    
    func getCount(for clientID: String, periodType: String, periodKey: String) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        
        let db = try conn.getHandle()
        let sql = "SELECT request_count FROM pan123_request_stats WHERE client_id = ? AND period_type = ? AND period_key = ? LIMIT 1;"
        let stmt = try SQLiteStatement(db: db, sql: sql)
        stmt.bindText(clientID, at: 1)
        stmt.bindText(periodType, at: 2)
        stmt.bindText(periodKey, at: 3)
        if stmt.step() == SQLITE_ROW {
            return Int(stmt.columnInt64(at: 0))
        }
        return 0
    }
    
    func incrementRequest(clientID: String, dayKey: String, minuteKey: String, now: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        
        let db = try conn.getHandle()
        let timestamp = now.timeIntervalSince1970
        
        // 1. 自增分钟统计
        let minSQL = """
        INSERT INTO pan123_request_stats (client_id, period_type, period_key, request_count, download_bytes, updated_at)
        VALUES (?, 'minute', ?, 1, 0, ?)
        ON CONFLICT(client_id, period_type, period_key) DO UPDATE SET
            request_count = request_count + 1,
            updated_at = excluded.updated_at;
        """
        let minStmt = try SQLiteStatement(db: db, sql: minSQL)
        minStmt.bindText(clientID, at: 1)
        minStmt.bindText(minuteKey, at: 2)
        minStmt.bindDouble(timestamp, at: 3)
        _ = minStmt.step()
        
        // 2. 自增当天统计
        let daySQL = """
        INSERT INTO pan123_request_stats (client_id, period_type, period_key, request_count, download_bytes, updated_at)
        VALUES (?, 'day', ?, 1, 0, ?)
        ON CONFLICT(client_id, period_type, period_key) DO UPDATE SET
            request_count = request_count + 1,
            updated_at = excluded.updated_at;
        """
        let dayStmt = try SQLiteStatement(db: db, sql: daySQL)
        dayStmt.bindText(clientID, at: 1)
        dayStmt.bindText(dayKey, at: 2)
        dayStmt.bindDouble(timestamp, at: 3)
        _ = dayStmt.step()
    }
}
