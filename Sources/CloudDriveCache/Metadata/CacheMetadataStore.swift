import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CloudDrivePersistence
import SQLite3

/// High-performance SQLite-backed cache metadata store.
/// Row-level operations eliminate full-file JSON serialization,
/// allowing instant LRU candidate evaluation and atomic policy updates.
public final class CacheMetadataStore: CacheMetadataStoreProtocol, @unchecked Sendable {
    private let conn: SQLiteConnection
    private let metadataURL: URL
    private let dbURL: URL
    private let migrationLock = NSLock()
    private var hasCheckedMigration = false
    private let healthLock = NSLock()
    private var databaseFailure: Error?
    public var isHealthy: Bool { healthLock.withLock { databaseFailure == nil } }
    private func recordFailure(_ error: Error) {
        healthLock.withLock { databaseFailure = error }
        Logger.shared.error(.cache, "Cache metadata unavailable; eviction is disabled: \(error)")
    }
    private func hasRow(_ stmt: SQLiteStatement) throws -> Bool {
        let code = stmt.step()
        if code == SQLITE_ROW { return true }
        if code == SQLITE_DONE { return false }
        throw DatabaseError.stepFailed(sql: "cache metadata query", code: code, message: "Cannot read complete cache metadata")
    }
    private func requireDone(_ stmt: SQLiteStatement) throws {
        let code = stmt.step()
        guard code == SQLITE_DONE else {
            throw DatabaseError.stepFailed(sql: "cache metadata mutation", code: code, message: "Cannot persist cache metadata")
        }
    }

    public init(metadataURL: URL = CloudDrivePaths.sharedDirectory.appendingPathComponent("Cache/metadata.json")) {
        self.metadataURL = metadataURL
        if metadataURL.pathExtension == "db" {
            self.dbURL = metadataURL
        } else {
            self.dbURL = metadataURL.deletingPathExtension().appendingPathExtension("db")
        }
        self.conn = SQLiteConnection(dbPath: dbURL)
        ensureSchema()
    }

    private func ensureSchema() {
        let schema = """
        CREATE TABLE IF NOT EXISTS cache_metadata (
            normalized_id TEXT PRIMARY KEY,
            file_id TEXT NOT NULL,
            size INTEGER NOT NULL DEFAULT 0,
            downloaded_at REAL NOT NULL,
            last_accessed_at REAL NOT NULL,
            policy TEXT NOT NULL DEFAULT 'automatic'
        );
        CREATE INDEX IF NOT EXISTS idx_cache_policy_access ON cache_metadata(policy, last_accessed_at ASC);
        """
        do {
            let columns = try SQLiteStatement(db: conn.getHandle(), sql: "PRAGMA table_info(cache_metadata);")
            var names = Set<String>()
            while try hasRow(columns) { names.insert(columns.columnText(at: 1)) }
            if !names.isEmpty && !names.contains("normalized_id") {
                let required: Set<String> = ["file_id", "size", "downloaded_at", "last_accessed_at", "policy"]
                guard required.isSubset(of: names) else { throw CocoaError(.fileReadCorruptFile) }
                try conn.withTransaction {
                    try conn.execute(sql: "ALTER TABLE cache_metadata RENAME TO cache_metadata_legacy;")
                    try conn.execute(sql: "DROP INDEX IF EXISTS idx_cache_policy_access;")
                    try conn.execute(sql: schema)
                    try conn.execute(sql: """
                    INSERT OR REPLACE INTO cache_metadata
                    SELECT CASE WHEN substr(file_id, 1, 1) = '/' THEN substr(file_id, 2) ELSE file_id END,
                           file_id, size, downloaded_at, last_accessed_at, policy
                    FROM cache_metadata_legacy
                    ORDER BY CASE WHEN policy = 'pinned' THEN 1 ELSE 0 END, last_accessed_at;
                    """)
                }
            } else { try conn.execute(sql: schema) }
        } catch { recordFailure(error) }
    }

    private func key(_ id: String) -> String {
        id.hasPrefix("/") ? String(id.dropFirst()) : id
    }

    private func checkMigrationIfNeeded() {
        migrationLock.lock()
        defer { migrationLock.unlock() }
        guard !hasCheckedMigration, isHealthy else { return }
        do {
            if metadataURL.pathExtension == "json" && FileManager.default.fileExists(atPath: metadataURL.path) {
                let decoded = try JSONDecoder().decode([String: CacheMetadata].self, from: Data(contentsOf: metadataURL))
                try conn.withTransaction {
                    for meta in decoded.values { try insertMetadataInternal(meta) }
                }
                // Keep the source until migration and archival both succeed.
                let backup = metadataURL.appendingPathExtension("bak")
                if FileManager.default.fileExists(atPath: backup.path) { throw CocoaError(.fileWriteFileExists) }
                try FileManager.default.moveItem(at: metadataURL, to: backup)
            }
            hasCheckedMigration = true
        } catch { recordFailure(error) }
    }

    private func insertMetadataInternal(_ metadata: CacheMetadata) throws {
        let sql = """
        INSERT OR REPLACE INTO cache_metadata (
            normalized_id, file_id, size, downloaded_at, last_accessed_at, policy
        ) VALUES (?, ?, ?, ?, ?, ?);
        """
        let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
        stmt.bindText(key(metadata.fileId), at: 1)
        stmt.bindText(metadata.fileId, at: 2)
        stmt.bindInt64(metadata.size, at: 3)
        stmt.bindDouble(metadata.downloadedAt.timeIntervalSince1970, at: 4)
        stmt.bindDouble(metadata.lastAccessedAt.timeIntervalSince1970, at: 5)
        stmt.bindText(metadata.policy.rawValue, at: 6)
        try requireDone(stmt)
    }

    public func get(for fileId: String) -> CacheMetadata? {
        checkMigrationIfNeeded()
        do {
            guard isHealthy else { throw CocoaError(.fileReadCorruptFile) }
            let sql = "SELECT file_id, size, downloaded_at, last_accessed_at, policy FROM cache_metadata WHERE normalized_id = ? LIMIT 1;"
            let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
            stmt.bindText(key(fileId), at: 1)
            if try hasRow(stmt) {
                let id = stmt.columnText(at: 0)
                let size = stmt.columnInt64(at: 1)
                let downloadedAt = Date(timeIntervalSince1970: stmt.columnDouble(at: 2))
                let lastAccessedAt = Date(timeIntervalSince1970: stmt.columnDouble(at: 3))
                guard let policy = CachePolicy(rawValue: stmt.columnText(at: 4)) else { throw CocoaError(.fileReadCorruptFile) }
                return CacheMetadata(fileId: id, size: size, downloadedAt: downloadedAt, lastAccessedAt: lastAccessedAt, policy: policy)
            }
            return nil
        } catch {
            recordFailure(error)
            return nil
        }
    }

    public func set(_ metadata: CacheMetadata) {
        checkMigrationIfNeeded()
        do {
            guard isHealthy else { throw CocoaError(.fileReadCorruptFile) }
            try conn.withTransaction {
                try insertMetadataInternal(metadata)
            }
        } catch {
            recordFailure(error)
            Logger.shared.error(.cache, "Failed to set cache metadata: \(error)")
        }
    }

    public func remove(for fileId: String) -> CacheMetadata? {
        checkMigrationIfNeeded()
        do {
            guard isHealthy else { throw CocoaError(.fileReadCorruptFile) }
            return try conn.withTransaction {
                let existing = get(for: fileId)
                guard existing != nil else { return nil }
                let sql = "DELETE FROM cache_metadata WHERE normalized_id = ?;"
                let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
                stmt.bindText(key(fileId), at: 1)
                try requireDone(stmt)
                return existing
            }
        } catch {
            recordFailure(error)
            return nil
        }
    }

    public func removePrefix(_ prefix: String) -> [String] {
        checkMigrationIfNeeded()
        let normalized = key(prefix)
        do {
            return try conn.withTransaction {
                let sql = "SELECT file_id FROM cache_metadata WHERE normalized_id = ? OR instr(normalized_id, ?) = 1;"
                let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
                stmt.bindText(normalized, at: 1)
                stmt.bindText("\(normalized)/", at: 2)
                var ids: [String] = []
                while try hasRow(stmt) {
                    ids.append(stmt.columnText(at: 0))
                }
                let delSQL = "DELETE FROM cache_metadata WHERE normalized_id = ? OR instr(normalized_id, ?) = 1;"
                let delStmt = try SQLiteStatement(db: try conn.getHandle(), sql: delSQL)
                delStmt.bindText(normalized, at: 1)
                delStmt.bindText("\(normalized)/", at: 2)
                try requireDone(delStmt)
                return ids
            }
        } catch {
            recordFailure(error)
            return []
        }
    }

    public func updateLastAccessed(for fileId: String, date: Date = Date()) {
        checkMigrationIfNeeded()
        do {
            guard isHealthy else { throw CocoaError(.fileReadCorruptFile) }
            try conn.withTransaction {
                let sql = "UPDATE cache_metadata SET last_accessed_at = ? WHERE normalized_id = ?;"
                let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
                stmt.bindDouble(date.timeIntervalSince1970, at: 1)
                stmt.bindText(key(fileId), at: 2)
                try requireDone(stmt)
            }
        } catch { recordFailure(error) }
    }

    public func setPolicy(for fileId: String, policy: CachePolicy) {
        checkMigrationIfNeeded()
        do {
            guard isHealthy else { throw CocoaError(.fileReadCorruptFile) }
            try conn.withTransaction {
                if let existing = get(for: fileId) {
                    let sql = "UPDATE cache_metadata SET policy = ? WHERE normalized_id = ?;"
                    let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
                    stmt.bindText(policy.rawValue, at: 1)
                    stmt.bindText(key(fileId), at: 2)
                    try requireDone(stmt)
                } else {
                    try insertMetadataInternal(CacheMetadata(
                        fileId: fileId,
                        size: 0,
                        downloadedAt: .distantPast,
                        lastAccessedAt: Date(),
                        policy: policy
                    ))
                }
            }
        } catch { recordFailure(error) }
    }

    public func getAllMetadata() -> [String: CacheMetadata] {
        checkMigrationIfNeeded()
        do {
            guard isHealthy else { throw CocoaError(.fileReadCorruptFile) }
            let sql = "SELECT file_id, size, downloaded_at, last_accessed_at, policy FROM cache_metadata;"
            let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
            var dict: [String: CacheMetadata] = [:]
            while try hasRow(stmt) {
                let id = stmt.columnText(at: 0)
                let size = stmt.columnInt64(at: 1)
                let downloadedAt = Date(timeIntervalSince1970: stmt.columnDouble(at: 2))
                let lastAccessedAt = Date(timeIntervalSince1970: stmt.columnDouble(at: 3))
                guard let policy = CachePolicy(rawValue: stmt.columnText(at: 4)) else { throw CocoaError(.fileReadCorruptFile) }
                dict[id] = CacheMetadata(fileId: id, size: size, downloadedAt: downloadedAt, lastAccessedAt: lastAccessedAt, policy: policy)
            }
            return dict
        } catch {
            recordFailure(error)
            return [:]
        }
    }

    public func getAllKeys() -> [String] {
        checkMigrationIfNeeded()
        do {
            guard isHealthy else { throw CocoaError(.fileReadCorruptFile) }
            let sql = "SELECT file_id FROM cache_metadata;"
            let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
            var keys: [String] = []
            while try hasRow(stmt) {
                keys.append(stmt.columnText(at: 0))
            }
            return keys
        } catch {
            recordFailure(error)
            return []
        }
    }

    public func getAllPinnedFileIds() -> [String] {
        checkMigrationIfNeeded()
        do {
            guard isHealthy else { throw CocoaError(.fileReadCorruptFile) }
            let sql = "SELECT file_id FROM cache_metadata WHERE policy = 'pinned';"
            let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
            var keys: [String] = []
            while try hasRow(stmt) {
                keys.append(stmt.columnText(at: 0))
            }
            return keys
        } catch {
            recordFailure(error)
            return []
        }
    }

    public func getStatistics() -> (totalSize: Int64, fileCount: Int) {
        checkMigrationIfNeeded()
        do {
            guard isHealthy else { throw CocoaError(.fileReadCorruptFile) }
            let sql = "SELECT COALESCE(SUM(size), 0), COUNT(*) FROM cache_metadata WHERE downloaded_at > -62135596800;"
            let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
            if try hasRow(stmt) {
                return (stmt.columnInt64(at: 0), Int(stmt.columnInt64(at: 1)))
            }
            return (0, 0)
        } catch {
            recordFailure(error)
            return (0, 0)
        }
    }

    public func getDynamicStatistics() -> (totalSize: Int64, fileCount: Int) {
        checkMigrationIfNeeded()
        do {
            guard isHealthy else { throw CocoaError(.fileReadCorruptFile) }
            let sql = "SELECT COALESCE(SUM(size), 0), COUNT(*) FROM cache_metadata WHERE policy != 'pinned' AND downloaded_at > -62135596800;"
            let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
            if try hasRow(stmt) {
                return (stmt.columnInt64(at: 0), Int(stmt.columnInt64(at: 1)))
            }
            return (0, 0)
        } catch {
            recordFailure(error)
            return (0, 0)
        }
    }

    public func getPinnedStatistics() -> (totalSize: Int64, fileCount: Int) {
        checkMigrationIfNeeded()
        do {
            guard isHealthy else { throw CocoaError(.fileReadCorruptFile) }
            let sql = "SELECT COALESCE(SUM(size), 0), COUNT(*) FROM cache_metadata WHERE policy = 'pinned' AND downloaded_at > -62135596800;"
            let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
            if try hasRow(stmt) {
                return (stmt.columnInt64(at: 0), Int(stmt.columnInt64(at: 1)))
            }
            return (0, 0)
        } catch {
            recordFailure(error)
            return (0, 0)
        }
    }

    public func clearAll() {
        checkMigrationIfNeeded()
        do {
            guard isHealthy else { throw CocoaError(.fileReadCorruptFile) }
            try conn.execute(sql: "DELETE FROM cache_metadata;")
        } catch { recordFailure(error) }
    }

    public func getEvictionCandidates(limit: Int = 100) -> [CacheMetadata] {
        checkMigrationIfNeeded()
        do {
            guard isHealthy else { throw CocoaError(.fileReadCorruptFile) }
            let sql = """
            SELECT file_id, size, downloaded_at, last_accessed_at, policy
            FROM cache_metadata
            WHERE policy != 'pinned'
            ORDER BY CASE WHEN policy = 'temporary' THEN 0 ELSE 1 END ASC, last_accessed_at ASC
            LIMIT ?;
            """
            let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
            stmt.bindInt64(Int64(limit), at: 1)
            var candidates: [CacheMetadata] = []
            while try hasRow(stmt) {
                let id = stmt.columnText(at: 0)
                let size = stmt.columnInt64(at: 1)
                let downloadedAt = Date(timeIntervalSince1970: stmt.columnDouble(at: 2))
                let lastAccessedAt = Date(timeIntervalSince1970: stmt.columnDouble(at: 3))
                guard let policy = CachePolicy(rawValue: stmt.columnText(at: 4)) else { throw CocoaError(.fileReadCorruptFile) }
                candidates.append(CacheMetadata(fileId: id, size: size, downloadedAt: downloadedAt, lastAccessedAt: lastAccessedAt, policy: policy))
            }
            return candidates
        } catch {
            recordFailure(error)
            return []
        }
    }

    public func save(immediate: Bool = false) {}
    public func reloadIfNeeded() {}
}
