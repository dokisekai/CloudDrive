import Foundation
import CloudDriveContracts
import CloudDrivePersistence
import SQLite3

extension OfflineSyncQueue {
    public func claimItem(id: String) throws -> SyncQueueItem? {
        try checkMigrationIfNeeded()
        return try conn.withTransaction {
            let now = Date().timeIntervalSince1970
            let updateSQL = "UPDATE sync_queue SET started_at = ? WHERE id = ?;"
            let updateStmt = try SQLiteStatement(db: try conn.getHandle(), sql: updateSQL)
            updateStmt.bindDouble(now, at: 1)
            updateStmt.bindText(id, at: 2)
            guard updateStmt.step() == SQLITE_DONE else { return nil }

            let selectSQL = """
            SELECT id, vault_id, file_id, operation_json, retry_count, last_error,
                   created_at, started_at, next_attempt_at, blocked_by_conflict,
                   is_auth_failure, is_permanent_failure, expected_etag
            FROM sync_queue WHERE id = ? LIMIT 1;
            """
            let selectStmt = try SQLiteStatement(db: try conn.getHandle(), sql: selectSQL)
            selectStmt.bindText(id, at: 1)
            if selectStmt.step() == SQLITE_ROW {
                return parseItem(stmt: selectStmt)
            }
            return nil
        }
    }

    public func resetAbandonedItems(olderThan interval: TimeInterval = 60.0) throws {
        try checkMigrationIfNeeded()
        try conn.withTransaction {
            let threshold = Date().addingTimeInterval(-interval).timeIntervalSince1970
            let sql = "UPDATE sync_queue SET started_at = NULL WHERE started_at IS NOT NULL AND started_at < ?;"
            let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
            stmt.bindDouble(threshold, at: 1)
            _ = stmt.step()
        }
    }

    public func resetStartedAt(id: String) throws {
        try checkMigrationIfNeeded()
        try conn.withTransaction {
            let sql = "UPDATE sync_queue SET started_at = NULL WHERE id = ?;"
            let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
            stmt.bindText(id, at: 1)
            _ = stmt.step()
        }
    }

    func acquireConsumerLease() throws -> SyncFileLease? {
        try SyncFileLease(url: dbURL.appendingPathExtension("consumer.lock"), nonBlocking: true)
    }
}
