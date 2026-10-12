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
                guard stmt.step() == SQLITE_DONE else { throw SyncError.operationFailed("Cannot persist sync operation state") }
            }
        } catch { log(error) }
    }

    public func removeItemsPersistent(ids: [String]) throws {
        try checkMigrationIfNeeded()
        try conn.withTransaction {
            for id in ids {
                let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: "DELETE FROM sync_queue WHERE id = ?;")
                stmt.bindText(id, at: 1)
                guard stmt.step() == SQLITE_DONE else { throw SyncError.operationFailed("Cannot remove sync operation") }
            }
        }
    }

    @discardableResult
    public func removeUnstartedItemsPersistent(ids: [String]) throws -> Set<String> {
        try checkMigrationIfNeeded()
        return try conn.withTransaction {
            var removed = Set<String>()
            for id in ids {
                let statement = try SQLiteStatement(db: try conn.getHandle(), sql: "DELETE FROM sync_queue WHERE id = ? AND started_at IS NULL;")
                statement.bindText(id, at: 1)
                guard statement.step() == SQLITE_DONE else {
                    throw SyncError.operationFailed("Cannot cancel unstarted sync operation")
                }
                if sqlite3_changes(try conn.getHandle()) == 1 { removed.insert(id) }
            }
            return removed
        }
    }

    func completeItem(id: String, fileId: String, etag: String?, replacement: VirtualFileItem? = nil) throws -> Bool {
        try checkMigrationIfNeeded()
        return try conn.withTransaction {
            let existsSQL = "SELECT 1 FROM sync_queue WHERE id = ? LIMIT 1;"
            let existsStmt = try SQLiteStatement(db: try conn.getHandle(), sql: existsSQL)
            existsStmt.bindText(id, at: 1)
            let exists = try hasRow(existsStmt)

            if !exists {
                let targetId = replacement?.id ?? fileId
                let checkSQL = "SELECT 1 FROM sync_queue WHERE file_id = ? LIMIT 1;"
                let checkStmt = try SQLiteStatement(db: try conn.getHandle(), sql: checkSQL)
                checkStmt.bindText(targetId, at: 1)
                return try hasRow(checkStmt)
            }

            let delSQL = "DELETE FROM sync_queue WHERE id = ?;"
            let delStmt = try SQLiteStatement(db: try conn.getHandle(), sql: delSQL)
            delStmt.bindText(id, at: 1)
            guard delStmt.step() == SQLITE_DONE else { throw SyncError.operationFailed("Cannot complete sync operation") }

            let effectiveId = replacement?.id ?? fileId
            if replacement == nil {
                // Only the immediate same-file successor consumes this revision.
                // Each successful version advances the chain; cancellation carries
                // the already-verified revision through the dependency trigger.
                try updateImmediateSuccessorETag(fileId: effectiveId, etag: etag)
                let check = try SQLiteStatement(db: try conn.getHandle(), sql: "SELECT 1 FROM sync_queue WHERE file_id = ? LIMIT 1;")
                check.bindText(effectiveId, at: 1)
                return try hasRow(check)
            }
            if effectiveId != fileId, let replacement {
                let items = try itemsForFilesPersistent(fileIds: [fileId], excludeId: id)
                let rewritten = items.map { item -> SyncQueueItem in
                    var changed = item
                    changed.operation = Self.rewrite(item.operation, oldId: fileId, newId: effectiveId, remotePath: replacement.remotePath ?? effectiveId, name: replacement.name, parentId: replacement.parentId)
                    return changed
                }
                try persistBatchItems(rewritten, affectedFileIds: [fileId, effectiveId])
            }
            try updateImmediateSuccessorETag(fileId: effectiveId, etag: etag)
            let check = try SQLiteStatement(db: try conn.getHandle(), sql: "SELECT 1 FROM sync_queue WHERE file_id = ? LIMIT 1;")
            check.bindText(effectiveId, at: 1)
            return try hasRow(check)
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
                guard stmt.step() == SQLITE_DONE else { throw SyncError.operationFailed("Cannot persist sync operation state") }
            }
        } catch { log(error) }
    }

    public func recordFailure(
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
            guard stmt.step() == SQLITE_DONE else { throw SyncError.operationFailed("Cannot persist sync operation state") }
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

    public func recoverFailedAndAbandonedOperations() {
        do {
            try checkMigrationIfNeeded()
            try conn.execute(sql: """
            UPDATE sync_queue
            SET started_at = NULL,
                next_attempt_at = NULL,
                blocked_by_conflict = 0,
                is_auth_failure = 0,
                is_permanent_failure = 0,
                retry_count = 0;
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
