import Foundation
import CloudDriveContracts
import CloudDrivePersistence
import SQLite3

extension OfflineSyncQueue {
    public func getCount() -> Int {
        do {
            try checkMigrationIfNeeded()
            let sql = "SELECT COUNT(*) FROM sync_queue;"
            let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
            if stmt.step() == SQLITE_ROW {
                return Int(stmt.columnInt64(at: 0))
            }
            return 0
        } catch {
            log(error)
            return 0
        }
    }

    public func getAllItems() -> [SyncQueueItem] {
        do {
            return try allItemsPersistent()
        } catch {
            log(error)
            return []
        }
    }

    public func allItemsPersistent() throws -> [SyncQueueItem] {
        try checkMigrationIfNeeded()
        let sql = """
        SELECT id, vault_id, file_id, operation_json, retry_count, last_error,
               created_at, started_at, next_attempt_at, blocked_by_conflict,
               is_auth_failure, is_permanent_failure, expected_etag
        FROM sync_queue ORDER BY created_at ASC;
        """
        let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
        var items: [SyncQueueItem] = []
        while try hasRow(stmt) {
            guard let item = parseItem(stmt: stmt) else { throw SyncError.operationFailed("Corrupted sync journal operation") }
            items.append(item)
        }
        return items
    }

    /// Only decode one eligible operation. Earlier operations on the same file,
    /// a parent directory or a move source must complete first, even after failure.
    func nextReadyItem(now: Date = Date()) throws -> SyncQueueItem? {
        try checkMigrationIfNeeded()
        let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: """
        SELECT q.id, q.vault_id, q.file_id, q.operation_json, q.retry_count, q.last_error,
               q.created_at, q.started_at, q.next_attempt_at, q.blocked_by_conflict,
               q.is_auth_failure, q.is_permanent_failure, q.expected_etag
        FROM sync_queue q INDEXED BY idx_sync_queue_runnable
        WHERE q.started_at IS NULL
          AND COALESCE(q.blocked_by_conflict, 0) = 0
          AND COALESCE(q.is_auth_failure, 0) = 0
          AND COALESCE(q.is_permanent_failure, 0) = 0
          AND (q.next_attempt_at IS NULL OR q.next_attempt_at <= ?)
          AND q.dependency_count = 0
        ORDER BY q.created_at, q.rowid LIMIT 1;
        """)
        stmt.bindDouble(now.timeIntervalSince1970, at: 1)
        let code = stmt.step()
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw SyncError.operationFailed("Cannot query sync scheduler (SQLite \(code))") }
        guard let item = parseItem(stmt: stmt) else {
            throw SyncError.operationFailed("Corrupted sync journal operation")
        }
        return item
    }

    func nextRetryDate() throws -> Date? {
        try checkMigrationIfNeeded()
        let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: """
        SELECT MIN(next_attempt_at) FROM sync_queue
        WHERE next_attempt_at > ? AND COALESCE(blocked_by_conflict, 0) = 0
          AND COALESCE(is_auth_failure, 0) = 0 AND COALESCE(is_permanent_failure, 0) = 0;
        """)
        stmt.bindDouble(Date().timeIntervalSince1970, at: 1)
        let code = stmt.step()
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw SyncError.operationFailed("Cannot query sync scheduler (SQLite \(code))") }
        return stmt.columnOptionalDouble(at: 0).map { Date(timeIntervalSince1970: $0) }
    }

    func findMoveSuccessor(sourcePath: String, excludeId: String) throws -> (movedId: String, targetPath: String)? {
        try checkMigrationIfNeeded()
        let statement = try SQLiteStatement(db: try conn.getHandle(), sql: """
        SELECT q.file_id, move.target_path FROM sync_queue_move_sources move
        JOIN sync_queue q ON q.id = move.item_id
        WHERE move.source_path = ? AND q.id != ?
        ORDER BY q.created_at, q.rowid LIMIT 1;
        """)
        statement.bindText(sourcePath, at: 1)
        statement.bindText(excludeId, at: 2)
        guard try hasRow(statement) else { return nil }
        return (statement.columnText(at: 0), statement.columnText(at: 1))
    }

    func successorStatus(fileIds: Set<String>, excludeId: String) throws -> SyncStatus? {
        try checkMigrationIfNeeded()
        guard !fileIds.isEmpty else { return nil }
        let placeholders = fileIds.map { _ in "?" }.joined(separator: ",")
        let statement = try SQLiteStatement(db: try conn.getHandle(), sql: "SELECT operation_json FROM sync_queue WHERE file_id IN (\(placeholders)) AND id != ? ORDER BY created_at, rowid LIMIT 1;")
        var index: Int32 = 1
        for fileId in fileIds { statement.bindText(fileId, at: index); index += 1 }
        statement.bindText(excludeId, at: index)
        guard try hasRow(statement) else { return nil }
        let operation = try JSONDecoder().decode(SyncOperation.self, from: Data(statement.columnText(at: 0).utf8))
        switch operation {
        case .move: return .pendingMove
        case .delete, .deleteItem: return .pendingDelete
        case .download: return .downloading
        default: return .pendingUpload
        }
    }

    public func itemsForFilePersistent(fileId: String) throws -> [SyncQueueItem] {
        let alternateId = fileId.hasPrefix("/") ? String(fileId.dropFirst()) : "/\(fileId)"
        return try itemsForFilesPersistent(fileIds: [fileId, alternateId], excludeId: "")
    }

    func itemsForFiles(fileIds: Set<String>, excludeId: String) -> [SyncQueueItem] {
        guard !fileIds.isEmpty else { return [] }
        do { return try itemsForFilesPersistent(fileIds: fileIds, excludeId: excludeId) }
        catch { log(error); return [] }
    }

    func itemsForFilesPersistent(fileIds: Set<String>, excludeId: String) throws -> [SyncQueueItem] {
            guard !fileIds.isEmpty else { return [] }
            try checkMigrationIfNeeded()
            let placeholders = fileIds.map { _ in "?" }.joined(separator: ", ")
            let sql = """
            SELECT id, vault_id, file_id, operation_json, retry_count, last_error,
                   created_at, started_at, next_attempt_at, blocked_by_conflict,
                   is_auth_failure, is_permanent_failure, expected_etag
            FROM sync_queue WHERE file_id IN (\(placeholders)) AND id != ?;
            """
            let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
            var index: Int32 = 1
            for fid in fileIds {
                stmt.bindText(fid, at: index)
                index += 1
            }
            stmt.bindText(excludeId, at: index)
            var items: [SyncQueueItem] = []
            while try hasRow(stmt) {
                guard let item = parseItem(stmt: stmt) else {
                    throw SyncError.operationFailed("Corrupted sync journal operation")
                }
                items.append(item)
            }
            return items
    }
}
