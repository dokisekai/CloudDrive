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
        let checkCol = "SELECT normalized_id FROM cache_metadata LIMIT 1;"
        if (try? conn.execute(sql: checkCol)) == nil {
            try? conn.execute(sql: "DROP TABLE IF EXISTS cache_metadata;")
        }
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
        try? conn.execute(sql: schema)
    }

    private func key(_ id: String) -> String {
        id.hasPrefix("/") ? String(id.dropFirst()) : id
    }

    private func checkMigrationIfNeeded() {
        migrationLock.lock()
        defer { migrationLock.unlock() }
        guard !hasCheckedMigration else { return }

        if metadataURL.pathExtension == "json" && FileManager.default.fileExists(atPath: metadataURL.path) {
            if let data = try? Data(contentsOf: metadataURL),
               let decoded = try? JSONDecoder().decode([String: CacheMetadata].self, from: data) {
                try? conn.withTransaction {
                    for (_, meta) in decoded {
                        try insertMetadataInternal(meta)
                    }
                }
                let bakURL = metadataURL.appendingPathExtension("bak")
                try? FileManager.default.removeItem(at: bakURL)
                try? FileManager.default.moveItem(at: metadataURL, to: bakURL)
            }
        }
        hasCheckedMigration = true
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
        _ = stmt.step()
    }

    public func get(for fileId: String) -> CacheMetadata? {
        checkMigrationIfNeeded()
        do {
            let sql = "SELECT file_id, size, downloaded_at, last_accessed_at, policy FROM cache_metadata WHERE normalized_id = ? LIMIT 1;"
            let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
            stmt.bindText(key(fileId), at: 1)
            if stmt.step() == SQLITE_ROW {
                let id = stmt.columnText(at: 0)
                let size = stmt.columnInt64(at: 1)
                let downloadedAt = Date(timeIntervalSince1970: stmt.columnDouble(at: 2))
                let lastAccessedAt = Date(timeIntervalSince1970: stmt.columnDouble(at: 3))
                let policy = CachePolicy(rawValue: stmt.columnText(at: 4)) ?? .automatic
                return CacheMetadata(fileId: id, size: size, downloadedAt: downloadedAt, lastAccessedAt: lastAccessedAt, policy: policy)
            }
            return nil
        } catch {
            return nil
        }
    }

    public func set(_ metadata: CacheMetadata) {
        checkMigrationIfNeeded()
        do {
            try conn.withTransaction {
                try insertMetadataInternal(metadata)
            }
        } catch {
            Logger.shared.error(.cache, "Failed to set cache metadata: \(error)")
        }
    }

    public func remove(for fileId: String) -> CacheMetadata? {
        checkMigrationIfNeeded()
        do {
            return try conn.withTransaction {
                let existing = get(for: fileId)
                guard existing != nil else { return nil }
                let sql = "DELETE FROM cache_metadata WHERE normalized_id = ?;"
                let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
                stmt.bindText(key(fileId), at: 1)
                _ = stmt.step()
                return existing
            }
        } catch {
            return nil
        }
    }

    public func removePrefix(_ prefix: String) -> [String] {
        checkMigrationIfNeeded()
        let normalized = key(prefix)
        do {
            return try conn.withTransaction {
                let sql = "SELECT file_id FROM cache_metadata WHERE normalized_id = ? OR normalized_id LIKE ?;"
                let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
                stmt.bindText(normalized, at: 1)
                stmt.bindText("\(normalized)/%", at: 2)
                var ids: [String] = []
                while stmt.step() == SQLITE_ROW {
                    ids.append(stmt.columnText(at: 0))
                }
                let delSQL = "DELETE FROM cache_metadata WHERE normalized_id = ? OR normalized_id LIKE ?;"
                let delStmt = try SQLiteStatement(db: try conn.getHandle(), sql: delSQL)
                delStmt.bindText(normalized, at: 1)
                delStmt.bindText("\(normalized)/%", at: 2)
                _ = delStmt.step()
                return ids
            }
        } catch {
            return []
        }
    }

    public func updateLastAccessed(for fileId: String, date: Date = Date()) {
        checkMigrationIfNeeded()
        do {
            try conn.withTransaction {
                let sql = "UPDATE cache_metadata SET last_accessed_at = ? WHERE normalized_id = ?;"
                let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
                stmt.bindDouble(date.timeIntervalSince1970, at: 1)
                stmt.bindText(key(fileId), at: 2)
                _ = stmt.step()
            }
        } catch {}
    }

    public func setPolicy(for fileId: String, policy: CachePolicy) {
        checkMigrationIfNeeded()
        do {
            try conn.withTransaction {
                if let existing = get(for: fileId) {
                    let sql = "UPDATE cache_metadata SET policy = ? WHERE normalized_id = ?;"
                    let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
                    stmt.bindText(policy.rawValue, at: 1)
                    stmt.bindText(key(fileId), at: 2)
                    _ = stmt.step()
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
        } catch {}
    }

    public func getAllMetadata() -> [String: CacheMetadata] {
        checkMigrationIfNeeded()
        do {
            let sql = "SELECT file_id, size, downloaded_at, last_accessed_at, policy FROM cache_metadata;"
            let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
            var dict: [String: CacheMetadata] = [:]
            while stmt.step() == SQLITE_ROW {
                let id = stmt.columnText(at: 0)
                let size = stmt.columnInt64(at: 1)
                let downloadedAt = Date(timeIntervalSince1970: stmt.columnDouble(at: 2))
                let lastAccessedAt = Date(timeIntervalSince1970: stmt.columnDouble(at: 3))
                let policy = CachePolicy(rawValue: stmt.columnText(at: 4)) ?? .automatic
                dict[id] = CacheMetadata(fileId: id, size: size, downloadedAt: downloadedAt, lastAccessedAt: lastAccessedAt, policy: policy)
            }
            return dict
        } catch {
            return [:]
        }
    }

    public func getAllKeys() -> [String] {
        checkMigrationIfNeeded()
        do {
            let sql = "SELECT file_id FROM cache_metadata;"
            let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
            var keys: [String] = []
            while stmt.step() == SQLITE_ROW {
                keys.append(stmt.columnText(at: 0))
            }
            return keys
        } catch {
            return []
        }
    }

    public func getAllPinnedFileIds() -> [String] {
        checkMigrationIfNeeded()
        do {
            let sql = "SELECT file_id FROM cache_metadata WHERE policy = 'pinned';"
            let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
            var keys: [String] = []
            while stmt.step() == SQLITE_ROW {
                keys.append(stmt.columnText(at: 0))
            }
            return keys
        } catch {
            return []
        }
    }

    public func getStatistics() -> (totalSize: Int64, fileCount: Int) {
        checkMigrationIfNeeded()
        do {
            let sql = "SELECT COALESCE(SUM(size), 0), COUNT(*) FROM cache_metadata WHERE downloaded_at > -62135596800;"
            let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
            if stmt.step() == SQLITE_ROW {
                return (stmt.columnInt64(at: 0), Int(stmt.columnInt64(at: 1)))
            }
            return (0, 0)
        } catch {
            return (0, 0)
        }
    }

    public func clearAll() {
        checkMigrationIfNeeded()
        do {
            try conn.execute(sql: "DELETE FROM cache_metadata;")
        } catch {}
    }

    public func getEvictionCandidates(limit: Int = 100) -> [CacheMetadata] {
        checkMigrationIfNeeded()
        do {
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
            while stmt.step() == SQLITE_ROW {
                let id = stmt.columnText(at: 0)
                let size = stmt.columnInt64(at: 1)
                let downloadedAt = Date(timeIntervalSince1970: stmt.columnDouble(at: 2))
                let lastAccessedAt = Date(timeIntervalSince1970: stmt.columnDouble(at: 3))
                let policy = CachePolicy(rawValue: stmt.columnText(at: 4)) ?? .automatic
                candidates.append(CacheMetadata(fileId: id, size: size, downloadedAt: downloadedAt, lastAccessedAt: lastAccessedAt, policy: policy))
            }
            return candidates
        } catch {
            return []
        }
    }

    public func save(immediate: Bool = false) {}
    public func reloadIfNeeded() {}
}
