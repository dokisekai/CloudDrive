import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CloudDrivePersistence
import SQLite3

extension OfflineSyncQueue {
    func ensureSchema() {
        let schema = """
        CREATE TABLE IF NOT EXISTS sync_queue (
            id TEXT PRIMARY KEY,
            vault_id TEXT,
            file_id TEXT NOT NULL,
            operation_json TEXT NOT NULL,
            retry_count INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            created_at REAL NOT NULL,
            started_at REAL,
            next_attempt_at REAL,
            blocked_by_conflict INTEGER NOT NULL DEFAULT 0,
            is_auth_failure INTEGER NOT NULL DEFAULT 0,
            is_permanent_failure INTEGER NOT NULL DEFAULT 0,
            expected_etag TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_sync_queue_order ON sync_queue(created_at ASC);
        CREATE INDEX IF NOT EXISTS idx_sync_queue_file ON sync_queue(file_id);
        """
        try? conn.execute(sql: schema)
    }

    func checkMigrationIfNeeded() throws {
        migrationLock.lock()
        defer { migrationLock.unlock() }
        guard !hasCheckedMigration else { return }
        
        if queueURL.pathExtension == "json" && FileManager.default.fileExists(atPath: queueURL.path) {
            let data = try Data(contentsOf: queueURL)
            if !data.isEmpty {
                // If the legacy file is corrupted, JSONDecoder will throw DecodingError
                // preserving the file content without silent overwrite.
                let items = try JSONDecoder().decode([SyncQueueItem].self, from: data)
                try conn.withTransaction {
                    for item in items {
                        try insertItemInternal(item)
                    }
                }
                let bakURL = queueURL.appendingPathExtension("bak")
                try? FileManager.default.removeItem(at: bakURL)
                try? FileManager.default.moveItem(at: queueURL, to: bakURL)
            } else {
                try? FileManager.default.removeItem(at: queueURL)
            }
        }
        hasCheckedMigration = true
    }

    func insertItemInternal(_ item: SyncQueueItem) throws {
        let sql = """
        INSERT OR REPLACE INTO sync_queue (
            id, vault_id, file_id, operation_json, retry_count, last_error,
            created_at, started_at, next_attempt_at, blocked_by_conflict,
            is_auth_failure, is_permanent_failure, expected_etag
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
        stmt.bindText(item.id, at: 1)
        stmt.bindOptionalText(item.vaultId, at: 2)
        stmt.bindText(item.operation.fileId, at: 3)
        let opData = try JSONEncoder().encode(item.operation)
        stmt.bindText(String(decoding: opData, as: UTF8.self), at: 4)
        stmt.bindInt64(Int64(item.retryCount), at: 5)
        stmt.bindOptionalText(item.lastError, at: 6)
        stmt.bindDouble(item.createdAt.timeIntervalSince1970, at: 7)
        stmt.bindOptionalDouble(item.startedAt?.timeIntervalSince1970, at: 8)
        stmt.bindOptionalDouble(item.nextAttemptAt?.timeIntervalSince1970, at: 9)
        stmt.bindOptionalBool(item.blockedByConflict, at: 10)
        stmt.bindOptionalBool(item.isAuthFailure, at: 11)
        stmt.bindOptionalBool(item.isPermanentFailure, at: 12)
        stmt.bindOptionalText(item.expectedETag, at: 13)
        if stmt.step() != SQLITE_DONE {
            throw DatabaseError.stepFailed(sql: sql, code: 1, message: "Failed to persist queue item")
        }
    }

    func parseItem(stmt: SQLiteStatement) -> SyncQueueItem? {
        let opText = stmt.columnText(at: 3)
        guard let opData = opText.data(using: .utf8),
              let op = try? JSONDecoder().decode(SyncOperation.self, from: opData) else {
            return nil
        }
        return SyncQueueItem(
            id: stmt.columnText(at: 0),
            operation: op,
            createdAt: Date(timeIntervalSince1970: stmt.columnDouble(at: 6)),
            retryCount: Int(stmt.columnInt64(at: 4)),
            lastError: stmt.columnOptionalText(at: 5),
            expectedETag: stmt.columnOptionalText(at: 12),
            nextAttemptAt: stmt.columnOptionalDouble(at: 8).map { Date(timeIntervalSince1970: $0) },
            blockedByConflict: stmt.columnOptionalBool(at: 9),
            startedAt: stmt.columnOptionalDouble(at: 7).map { Date(timeIntervalSince1970: $0) },
            vaultId: stmt.columnOptionalText(at: 1),
            isPermanentFailure: stmt.columnOptionalBool(at: 11),
            isAuthFailure: stmt.columnOptionalBool(at: 10)
        )
    }

    func log(_ error: Error) {
        Logger.shared.error(.sync, "Sync journal access failed: \(error.localizedDescription)")
    }
}
