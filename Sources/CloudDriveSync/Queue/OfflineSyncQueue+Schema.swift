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
            expected_etag TEXT,
            dependency_count INTEGER NOT NULL DEFAULT 0
        );
        """
        do { try conn.execute(sql: schema) } catch { schemaError = error }
        do {
            let columns = try SQLiteStatement(db: try conn.getHandle(), sql: "PRAGMA table_info(sync_queue);")
            var hasDependencyCount = false
            while try hasRow(columns) {
                if columns.columnText(at: 1) == "dependency_count" { hasDependencyCount = true }
            }
            if !hasDependencyCount { try conn.execute(sql: "ALTER TABLE sync_queue ADD COLUMN dependency_count INTEGER NOT NULL DEFAULT 0;") }
        } catch { if schemaError == nil { schemaError = error } }
        // Execute schema changes separately so individual errors remain visible.
        for sql in [
            "PRAGMA synchronous = FULL;",
            "CREATE INDEX IF NOT EXISTS idx_sync_queue_order ON sync_queue(created_at ASC);",
            "CREATE INDEX IF NOT EXISTS idx_sync_queue_file ON sync_queue(file_id, created_at);",
            "CREATE INDEX IF NOT EXISTS idx_sync_queue_runnable ON sync_queue(created_at) WHERE dependency_count = 0 AND started_at IS NULL AND COALESCE(blocked_by_conflict, 0) = 0 AND COALESCE(is_auth_failure, 0) = 0 AND COALESCE(is_permanent_failure, 0) = 0;",
            "CREATE INDEX IF NOT EXISTS idx_sync_queue_ready ON sync_queue(created_at) WHERE started_at IS NULL AND COALESCE(blocked_by_conflict, 0) = 0 AND COALESCE(is_auth_failure, 0) = 0 AND COALESCE(is_permanent_failure, 0) = 0;",
            "CREATE TABLE IF NOT EXISTS sync_queue_move_sources (item_id TEXT PRIMARY KEY, source_path TEXT NOT NULL, target_path TEXT NOT NULL);",
            "CREATE INDEX IF NOT EXISTS idx_sync_queue_move_source ON sync_queue_move_sources(source_path);",
            "CREATE TRIGGER IF NOT EXISTS sync_queue_move_cleanup AFTER DELETE ON sync_queue BEGIN DELETE FROM sync_queue_move_sources WHERE item_id = OLD.id; END;",
            "CREATE TABLE IF NOT EXISTS sync_commit_journal (id TEXT PRIMARY KEY, entry_json TEXT NOT NULL);",
            "CREATE TABLE IF NOT EXISTS sync_queue_dependencies (item_id TEXT NOT NULL, file_id TEXT NOT NULL, PRIMARY KEY(item_id, file_id));",
            "CREATE TABLE IF NOT EXISTS sync_queue_dependency_edges (item_id TEXT NOT NULL, predecessor_id TEXT NOT NULL, PRIMARY KEY(item_id, predecessor_id));",
            "CREATE INDEX IF NOT EXISTS idx_sync_queue_edge_predecessor ON sync_queue_dependency_edges(predecessor_id, item_id);",
            "DROP TRIGGER IF EXISTS sync_queue_edge_cleanup;",
            "CREATE TABLE IF NOT EXISTS sync_queue_schema_versions (name TEXT PRIMARY KEY);",
            "DROP TRIGGER IF EXISTS sync_queue_edge_cleanup_v2;",
            "CREATE TRIGGER IF NOT EXISTS sync_queue_edge_cleanup_v3 AFTER DELETE ON sync_queue BEGIN UPDATE sync_queue SET expected_etag = OLD.expected_etag WHERE file_id = OLD.file_id AND id IN (SELECT item_id FROM sync_queue_dependency_edges WHERE predecessor_id = OLD.id); INSERT OR IGNORE INTO sync_queue_dependency_edges(item_id, predecessor_id) SELECT dependent.item_id, predecessor.predecessor_id FROM sync_queue_dependency_edges dependent JOIN sync_queue_dependency_edges predecessor ON predecessor.item_id = OLD.id WHERE dependent.predecessor_id = OLD.id AND dependent.item_id != predecessor.predecessor_id; UPDATE sync_queue SET dependency_count = (SELECT COUNT(*) FROM sync_queue_dependency_edges WHERE item_id = sync_queue.id AND predecessor_id != OLD.id) WHERE id IN (SELECT item_id FROM sync_queue_dependency_edges WHERE predecessor_id = OLD.id); DELETE FROM sync_queue_dependency_edges WHERE predecessor_id = OLD.id OR item_id = OLD.id; END;",
            "CREATE INDEX IF NOT EXISTS idx_sync_queue_dependency_file ON sync_queue_dependencies(file_id, item_id);",
            "CREATE TRIGGER IF NOT EXISTS sync_queue_dependency_cleanup AFTER DELETE ON sync_queue BEGIN DELETE FROM sync_queue_dependencies WHERE item_id = OLD.id; END;"
        ] {
            do { try conn.execute(sql: sql) }
            catch { if schemaError == nil { schemaError = error } }
        }
    }

    func checkMigrationIfNeeded() throws {
        migrationLock.lock()
        defer { migrationLock.unlock() }
        if let schemaError { throw schemaError }
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
        // Backfill only legacy rows; subsequent mutations maintain the index.
        let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: """
        SELECT id, vault_id, file_id, operation_json, retry_count, last_error,
               created_at, started_at, next_attempt_at, blocked_by_conflict,
               is_auth_failure, is_permanent_failure, expected_etag
        FROM sync_queue WHERE NOT EXISTS (
            SELECT 1 FROM sync_queue_dependencies WHERE item_id = sync_queue.id
        );
        """)
        var legacy: [SyncQueueItem] = []
        while try hasRow(stmt) {
            guard let item = parseItem(stmt: stmt) else {
                throw SyncError.operationFailed("Corrupted sync journal operation")
            }
            legacy.append(item)
        }
        try conn.withTransaction {
            for item in legacy { try indexDependencies(item) }
        }
        let moves = try SQLiteStatement(db: try conn.getHandle(), sql: """
        SELECT id, vault_id, file_id, operation_json, retry_count, last_error,
               created_at, started_at, next_attempt_at, blocked_by_conflict,
               is_auth_failure, is_permanent_failure, expected_etag
        FROM sync_queue WHERE operation_json LIKE '%"move"%' AND NOT EXISTS (
            SELECT 1 FROM sync_queue_move_sources WHERE item_id = sync_queue.id
        );
        """)
        var legacyMoves: [SyncQueueItem] = []
        while try hasRow(moves) {
            guard let item = parseItem(stmt: moves) else { throw SyncError.operationFailed("Corrupted legacy move operation") }
            legacyMoves.append(item)
        }
        try conn.withTransaction { for item in legacyMoves { try indexMoveSource(item) } }
        // Upgrade old queues once. Thereafter each enqueue/rename maintains edges
        // and the deletion trigger releases exactly the dependent successors.
        try conn.withTransaction {
            let upgraded = try SQLiteStatement(db: try conn.getHandle(), sql: "SELECT 1 FROM sync_queue_schema_versions WHERE name = 'dependency-edges-v2';")
            if try !hasRow(upgraded) {
                try conn.execute(sql: "DELETE FROM sync_queue_dependency_edges;")
                try conn.execute(sql: """
                INSERT OR IGNORE INTO sync_queue_dependency_edges(item_id, predecessor_id)
                SELECT q.id, (
                    SELECT predecessor.id FROM sync_queue predecessor
                    WHERE predecessor.file_id = d.file_id AND predecessor.id != q.id
                      AND (predecessor.created_at < q.created_at OR
                           (predecessor.created_at = q.created_at AND predecessor.rowid < q.rowid))
                    ORDER BY predecessor.created_at DESC, predecessor.rowid DESC LIMIT 1
                ) AS predecessor_id
                FROM sync_queue q JOIN sync_queue_dependencies d ON d.item_id = q.id
                WHERE predecessor_id IS NOT NULL;
                """)
                try conn.execute(sql: "UPDATE sync_queue SET dependency_count = (SELECT COUNT(*) FROM sync_queue_dependency_edges WHERE item_id = sync_queue.id);")
                try conn.execute(sql: "INSERT INTO sync_queue_schema_versions(name) VALUES ('dependency-edges-v2');")
            }
        }
        hasCheckedMigration = true
    }

    func insertItemInternal(_ item: SyncQueueItem, maintainDependencies: Bool = true) throws {
        let sql = """
        INSERT INTO sync_queue (
            id, vault_id, file_id, operation_json, retry_count, last_error,
            created_at, started_at, next_attempt_at, blocked_by_conflict,
            is_auth_failure, is_permanent_failure, expected_etag
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            vault_id = excluded.vault_id, file_id = excluded.file_id,
            operation_json = excluded.operation_json, retry_count = excluded.retry_count,
            last_error = excluded.last_error, created_at = excluded.created_at,
            started_at = excluded.started_at, next_attempt_at = excluded.next_attempt_at,
            blocked_by_conflict = excluded.blocked_by_conflict,
            is_auth_failure = excluded.is_auth_failure,
            is_permanent_failure = excluded.is_permanent_failure,
            expected_etag = excluded.expected_etag;
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
        stmt.bindBool(item.blockedByConflict ?? false, at: 10)
        stmt.bindBool(item.isAuthFailure ?? false, at: 11)
        stmt.bindBool(item.isPermanentFailure ?? false, at: 12)
        stmt.bindOptionalText(item.expectedETag, at: 13)
        if stmt.step() != SQLITE_DONE {
            throw DatabaseError.stepFailed(sql: sql, code: 1, message: "Failed to persist queue item")
        }
        if maintainDependencies { try indexDependencies(item) }
    }

    func indexDependencies(_ item: SyncQueueItem, rebuildEdges: Bool = true) throws {
        let remove = try SQLiteStatement(db: try conn.getHandle(), sql: "DELETE FROM sync_queue_dependencies WHERE item_id = ?;")
        remove.bindText(item.id, at: 1)
        guard remove.step() == SQLITE_DONE else { throw SyncError.operationFailed("Cannot update sync dependencies") }
        var keys = Set<String>()
        var roots = [item.operation.fileId]
        if let parent = item.operation.parentId { roots.append(parent) }
        if case .move(_, let source, _) = item.operation { roots.append(source) }
        for root in roots {
            var path = root
            keys.insert(path)
            while let slash = path.lastIndex(of: "/") {
                path = String(path[..<slash])
                keys.insert(path.isEmpty ? "/" : path)
                if path.isEmpty { break }
            }
        }
        for key in keys {
            let insert = try SQLiteStatement(db: try conn.getHandle(), sql: "INSERT OR IGNORE INTO sync_queue_dependencies(item_id, file_id) VALUES (?, ?);")
            insert.bindText(item.id, at: 1)
            insert.bindText(key, at: 2)
            guard insert.step() == SQLITE_DONE else { throw SyncError.operationFailed("Cannot persist sync dependencies") }
        }
        try indexMoveSource(item)
        guard rebuildEdges else { return }
        let newest = try SQLiteStatement(db: try conn.getHandle(), sql: "SELECT id FROM sync_queue ORDER BY created_at DESC, rowid DESC LIMIT 1;")
        let isAppend = try hasRow(newest) && newest.columnText(at: 0) == item.id
        if isAppend {
            try rebuildDependencyEdges(itemId: item.id)
            return
        }
        // A prepared intent can be inserted after a later timestamped task,
        // and renames can introduce a predecessor identity for existing rows.
        let dependents = try SQLiteStatement(db: try conn.getHandle(), sql: """
        SELECT DISTINCT successor.id FROM sync_queue successor
        JOIN sync_queue_dependencies dependency ON dependency.item_id = successor.id
        JOIN sync_queue predecessor ON predecessor.id = ?
        WHERE dependency.file_id = predecessor.file_id AND successor.id != predecessor.id
          AND (predecessor.created_at < successor.created_at OR
               (predecessor.created_at = successor.created_at AND predecessor.rowid < successor.rowid));
        """)
        dependents.bindText(item.id, at: 1)
        var dependentIds: [String] = []
        while try hasRow(dependents) { dependentIds.append(dependents.columnText(at: 0)) }
        for id in dependentIds { try rebuildDependencyEdges(itemId: id) }
        try rebuildDependencyEdges(itemId: item.id)
    }

    func indexMoveSource(_ item: SyncQueueItem) throws {
        let remove = try SQLiteStatement(db: try conn.getHandle(), sql: "DELETE FROM sync_queue_move_sources WHERE item_id = ?;")
        remove.bindText(item.id, at: 1)
        guard remove.step() == SQLITE_DONE else { throw SyncError.operationFailed("Cannot update move source index") }
        if case .move(_, let source, let target) = item.operation {
            let insert = try SQLiteStatement(db: try conn.getHandle(), sql: "INSERT INTO sync_queue_move_sources(item_id, source_path, target_path) VALUES (?, ?, ?);")
            insert.bindText(item.id, at: 1)
            insert.bindText(source, at: 2)
            insert.bindText(target, at: 3)
            guard insert.step() == SQLITE_DONE else { throw SyncError.operationFailed("Cannot persist move source index") }
        }
    }

    /// Identity changes first update every row/key, then rebuild each affected
    /// successor once. Rebuilding all later versions after each row was quadratic.
    func persistBatchItems(_ items: [SyncQueueItem], affectedFileIds: Set<String>) throws {
        guard !items.isEmpty else { return }
        for item in items { try insertItemInternal(item, maintainDependencies: false) }
        for item in items { try indexDependencies(item, rebuildEdges: false) }
        var affectedIds = Set(items.map { $0.id })
        let keys = Array(affectedFileIds.union(items.map { $0.operation.fileId }))
        for start in stride(from: 0, to: keys.count, by: 400) {
            let batch = Array(keys[start..<min(start + 400, keys.count)])
            let placeholders = batch.map { _ in "?" }.joined(separator: ",")
            let statement = try SQLiteStatement(db: try conn.getHandle(), sql: "SELECT DISTINCT item_id FROM sync_queue_dependencies WHERE file_id IN (\(placeholders));")
            for (index, key) in batch.enumerated() { statement.bindText(key, at: Int32(index + 1)) }
            while try hasRow(statement) { affectedIds.insert(statement.columnText(at: 0)) }
        }
        for id in affectedIds { try rebuildDependencyEdges(itemId: id) }
    }

    func updateImmediateSuccessorETag(fileId: String, etag: String?) throws {
        let statement = try SQLiteStatement(db: try conn.getHandle(), sql: "UPDATE sync_queue SET expected_etag = ? WHERE id = (SELECT id FROM sync_queue WHERE file_id = ? ORDER BY created_at, rowid LIMIT 1);")
        statement.bindOptionalText(etag, at: 1)
        statement.bindText(fileId, at: 2)
        guard statement.step() == SQLITE_DONE else { throw SyncError.operationFailed("Cannot update successor version") }
    }

    func rebuildDependencyEdges(itemId: String) throws {
        let remove = try SQLiteStatement(db: try conn.getHandle(), sql: "DELETE FROM sync_queue_dependency_edges WHERE item_id = ?;")
        remove.bindText(itemId, at: 1)
        guard remove.step() == SQLITE_DONE else { throw SyncError.operationFailed("Cannot rebuild sync edges") }
        let insert = try SQLiteStatement(db: try conn.getHandle(), sql: """
        INSERT OR IGNORE INTO sync_queue_dependency_edges(item_id, predecessor_id)
        SELECT q.id, (
            SELECT predecessor.id FROM sync_queue predecessor
            WHERE predecessor.file_id = d.file_id AND predecessor.id != q.id
              AND (predecessor.created_at < q.created_at OR
                   (predecessor.created_at = q.created_at AND predecessor.rowid < q.rowid))
            ORDER BY predecessor.created_at DESC, predecessor.rowid DESC LIMIT 1
        ) AS predecessor_id
        FROM sync_queue q JOIN sync_queue_dependencies d ON d.item_id = q.id
        WHERE q.id = ? AND predecessor_id IS NOT NULL;
        """)
        insert.bindText(itemId, at: 1)
        guard insert.step() == SQLITE_DONE else { throw SyncError.operationFailed("Cannot persist sync edges") }
        let count = try SQLiteStatement(db: try conn.getHandle(), sql: "UPDATE sync_queue SET dependency_count = (SELECT COUNT(*) FROM sync_queue_dependency_edges WHERE item_id = ?) WHERE id = ?;")
        count.bindText(itemId, at: 1)
        count.bindText(itemId, at: 2)
        guard count.step() == SQLITE_DONE else { throw SyncError.operationFailed("Cannot persist sync dependency count") }
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

    func hasRow(_ statement: SQLiteStatement) throws -> Bool {
        let code = statement.step()
        if code == SQLITE_ROW { return true }
        if code == SQLITE_DONE { return false }
        throw SyncError.operationFailed("Sync journal query failed (SQLite \(code))")
    }

    func log(_ error: Error) {
        Logger.shared.error(.sync, "Sync journal access failed: \(error.localizedDescription)")
    }
}
