import Foundation
import CloudDriveContracts
import CloudDrivePersistence
import SQLite3

extension OfflineSyncQueue {
    public func claimItem(id: String) throws -> SyncQueueItem? {
        try checkMigrationIfNeeded()
        return try conn.withTransaction {
            let now = Date().timeIntervalSince1970
            let updateSQL = "UPDATE sync_queue SET started_at = ? WHERE id = ? AND started_at IS NULL AND dependency_count = 0 AND COALESCE(blocked_by_conflict, 0) = 0 AND COALESCE(is_auth_failure, 0) = 0 AND COALESCE(is_permanent_failure, 0) = 0 AND (next_attempt_at IS NULL OR next_attempt_at <= ?);"
            let updateStmt = try SQLiteStatement(db: try conn.getHandle(), sql: updateSQL)
            updateStmt.bindDouble(now, at: 1)
            updateStmt.bindText(id, at: 2)
            updateStmt.bindDouble(now, at: 3)
            let updateCode = updateStmt.step()
            guard updateCode == SQLITE_DONE else { throw SyncError.operationFailed("Cannot claim sync operation (SQLite \(updateCode))") }
            guard sqlite3_changes(try conn.getHandle()) == 1 else { return nil }

            let selectSQL = """
            SELECT id, vault_id, file_id, operation_json, retry_count, last_error,
                   created_at, started_at, next_attempt_at, blocked_by_conflict,
                   is_auth_failure, is_permanent_failure, expected_etag
            FROM sync_queue WHERE id = ? LIMIT 1;
            """
            let selectStmt = try SQLiteStatement(db: try conn.getHandle(), sql: selectSQL)
            selectStmt.bindText(id, at: 1)
            let code = selectStmt.step()
            if code == SQLITE_DONE { return nil }
            guard code == SQLITE_ROW, let item = parseItem(stmt: selectStmt) else {
                throw SyncError.operationFailed("Cannot read claimed sync operation (SQLite \(code))")
            }
            return item
        }
    }

    public func resetAbandonedItems(olderThan interval: TimeInterval = 60.0) throws {
        try checkMigrationIfNeeded()
        try conn.withTransaction {
            let threshold = Date().addingTimeInterval(-interval).timeIntervalSince1970
            let sql = "UPDATE sync_queue SET started_at = NULL WHERE started_at IS NOT NULL AND started_at < ?;"
            let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
            stmt.bindDouble(threshold, at: 1)
            let code = stmt.step()
            guard code == SQLITE_DONE else { throw SyncError.operationFailed("Cannot persist sync lease state (SQLite \(code))") }
        }
    }

    public func resetStartedAt(id: String) throws {
        try checkMigrationIfNeeded()
        try conn.withTransaction {
            let sql = "UPDATE sync_queue SET started_at = NULL WHERE id = ?;"
            let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
            stmt.bindText(id, at: 1)
            let code = stmt.step()
            guard code == SQLITE_DONE else { throw SyncError.operationFailed("Cannot persist sync lease state (SQLite \(code))") }
        }
    }

    /// 动态刷新长耗时任务的心跳时间，防止超大文件上传中途被误判为假死
    public func touchStartedAt(id: String) throws {
        try checkMigrationIfNeeded()
        try conn.withTransaction {
            let now = Date().timeIntervalSince1970
            let sql = "UPDATE sync_queue SET started_at = ? WHERE id = ?;"
            let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
            stmt.bindDouble(now, at: 1)
            stmt.bindText(id, at: 2)
            let code = stmt.step()
            guard code == SQLITE_DONE else { throw SyncError.operationFailed("Cannot persist sync lease state (SQLite \(code))") }
        }
    }

    func acquireConsumerLease() throws -> SyncFileLease? {
        try SyncFileLease(url: dbURL.appendingPathExtension("consumer.lock"), nonBlocking: true)
    }
}
