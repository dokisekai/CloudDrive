import Foundation
import CloudDriveContracts
import CloudDrivePersistence
import SQLite3

extension OfflineSyncQueue {
    public func removeItem(id: String) {
        do {
            try checkMigrationIfNeeded()
            try conn.withTransaction {
                let sql = "DELETE FROM sync_queue WHERE id = ?;"
                let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
                stmt.bindText(id, at: 1)
                _ = stmt.step()
            }
        } catch { log(error) }
    }

    func completeItem(id: String, fileId: String, etag: String?, replacement: VirtualFileItem? = nil) throws -> Bool {
        try checkMigrationIfNeeded()
        return try conn.withTransaction {
            let existsSQL = "SELECT 1 FROM sync_queue WHERE id = ? LIMIT 1;"
            let existsStmt = try SQLiteStatement(db: try conn.getHandle(), sql: existsSQL)
            existsStmt.bindText(id, at: 1)
            let exists = existsStmt.step() == SQLITE_ROW

            if !exists {
                let targetId = replacement?.id ?? fileId
                let checkSQL = "SELECT 1 FROM sync_queue WHERE file_id = ? LIMIT 1;"
                let checkStmt = try SQLiteStatement(db: try conn.getHandle(), sql: checkSQL)
                checkStmt.bindText(targetId, at: 1)
                return checkStmt.step() == SQLITE_ROW
            }

            let delSQL = "DELETE FROM sync_queue WHERE id = ?;"
            let delStmt = try SQLiteStatement(db: try conn.getHandle(), sql: delSQL)
            delStmt.bindText(id, at: 1)
            _ = delStmt.step()

            let effectiveId = replacement?.id ?? fileId
            let items = try allItemsPersistent()
            for var item in items {
                var changed = false
                if let replacement, effectiveId != fileId {
                    item.operation = Self.rewrite(item.operation, oldId: fileId, newId: effectiveId, remotePath: replacement.remotePath ?? effectiveId, name: replacement.name, parentId: replacement.parentId)
                    changed = true
                }
                if item.operation.fileId == effectiveId, let etag {
                    switch item.operation {
                    case .upload, .encryptedUpload:
                        item.expectedETag = etag
                        changed = true
                    default: break
                    }
                }
                if changed {
                    try insertItemInternal(item)
                }
            }
            return items.contains { $0.operation.fileId == effectiveId }
        }
    }

    public func updateItem(id: String, retryCount: Int, lastError: String?) {
        do {
            try checkMigrationIfNeeded()
            try conn.withTransaction {
                let sql = "UPDATE sync_queue SET retry_count = ?, last_error = ? WHERE id = ?;"
                let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
                stmt.bindInt64(Int64(retryCount), at: 1)
                stmt.bindOptionalText(lastError, at: 2)
                stmt.bindText(id, at: 3)
                _ = stmt.step()
            }
        } catch { log(error) }
    }

    func recordFailure(
        id: String,
        message: String,
        conflict: Bool,
        nextAttemptAt: Date?,
        isAuthFailure: Bool = false,
        isPermanentFailure: Bool = false
    ) throws {
        try checkMigrationIfNeeded()
        try conn.withTransaction {
            let sql = """
            UPDATE sync_queue
            SET retry_count = retry_count + 1,
                last_error = ?,
                blocked_by_conflict = ?,
                next_attempt_at = ?,
                is_auth_failure = ?,
                is_permanent_failure = ?,
                started_at = NULL
            WHERE id = ?;
            """
            let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
            stmt.bindText(message, at: 1)
            stmt.bindBool(conflict, at: 2)
            stmt.bindOptionalDouble(nextAttemptAt?.timeIntervalSince1970, at: 3)
            stmt.bindBool(isAuthFailure, at: 4)
            stmt.bindBool(isPermanentFailure, at: 5)
            stmt.bindText(id, at: 6)
            _ = stmt.step()
        }
    }

    public func retryFailedOperations() {
        do {
            try checkMigrationIfNeeded()
            try conn.execute(sql: """
            UPDATE sync_queue
            SET next_attempt_at = NULL,
                blocked_by_conflict = 0,
                is_auth_failure = 0,
                is_permanent_failure = 0;
            """)
        } catch { log(error) }
    }

    func retryTransientOperations() {
        do {
            try checkMigrationIfNeeded()
            try conn.execute(sql: """
            UPDATE sync_queue
            SET next_attempt_at = NULL
            WHERE blocked_by_conflict = 0
              AND is_auth_failure = 0
              AND is_permanent_failure = 0;
            """)
        } catch { log(error) }
    }
}
