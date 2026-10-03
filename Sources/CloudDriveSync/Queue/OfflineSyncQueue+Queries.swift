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

    func allItemsPersistent() throws -> [SyncQueueItem] {
        try checkMigrationIfNeeded()
        let sql = """
        SELECT id, vault_id, file_id, operation_json, retry_count, last_error,
               created_at, started_at, next_attempt_at, blocked_by_conflict,
               is_auth_failure, is_permanent_failure, expected_etag
        FROM sync_queue ORDER BY created_at ASC;
        """
        let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
        var items: [SyncQueueItem] = []
        while stmt.step() == SQLITE_ROW {
            if let item = parseItem(stmt: stmt) {
                items.append(item)
            }
        }
        return items
    }

    func findMoveSuccessor(sourcePath: String, excludeId: String) -> (movedId: String, targetPath: String)? {
        do {
            try checkMigrationIfNeeded()
            let sql = "SELECT operation_json FROM sync_queue WHERE id != ? AND operation_json LIKE '%\"move\"%';"
            let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
            stmt.bindText(excludeId, at: 1)
            while stmt.step() == SQLITE_ROW {
                let json = stmt.columnText(at: 0)
                if let data = json.data(using: .utf8),
                   let op = try? JSONDecoder().decode(SyncOperation.self, from: data),
                   case .move(let movedId, let source, let target) = op,
                   source == sourcePath {
                    return (movedId, target)
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    func itemsForFiles(fileIds: Set<String>, excludeId: String) -> [SyncQueueItem] {
        guard !fileIds.isEmpty else { return [] }
        do {
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
            while stmt.step() == SQLITE_ROW {
                if let item = parseItem(stmt: stmt) {
                    items.append(item)
                }
            }
            return items
        } catch {
            return []
        }
    }
}
