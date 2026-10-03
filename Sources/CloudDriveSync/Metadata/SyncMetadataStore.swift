import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CloudDrivePersistence
import SQLite3

/// High-performance SQLite-backed metadata store.
/// Row-level transactions eliminate full-file JSON serialization overhead,
/// allowing instant point queries and atomic status mutations.
public final class SyncMetadataStore: @unchecked Sendable {
    private let conn: SQLiteConnection
    private let metadataURL: URL
    private let dbURL: URL
    private let vaultId: String?
    private let migrationLock = NSLock()
    private var hasCheckedMigration = false

    public init(metadataURL: URL = CloudDrivePaths.sharedDirectory.appendingPathComponent("sync_metadata.json"), vaultId: String? = nil) {
        self.metadataURL = metadataURL
        self.vaultId = vaultId
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
        CREATE TABLE IF NOT EXISTS sync_metadata (
            file_id TEXT PRIMARY KEY,
            vault_id TEXT,
            name TEXT NOT NULL,
            parent_id TEXT NOT NULL,
            is_directory INTEGER NOT NULL DEFAULT 0,
            sync_status TEXT NOT NULL,
            local_path TEXT,
            remote_path TEXT,
            size INTEGER NOT NULL DEFAULT 0,
            local_modified_at REAL,
            remote_modified_at REAL,
            etag TEXT,
            download_progress REAL NOT NULL DEFAULT 0.0,
            last_sync_time REAL
        );
        CREATE INDEX IF NOT EXISTS idx_sync_metadata_parent ON sync_metadata(parent_id);
        CREATE INDEX IF NOT EXISTS idx_sync_metadata_status ON sync_metadata(sync_status);
        """
        try? conn.execute(sql: schema)
    }

    private func checkMigrationIfNeeded() throws {
        migrationLock.lock()
        defer { migrationLock.unlock() }
        guard !hasCheckedMigration else { return }

        if metadataURL.pathExtension == "json" && FileManager.default.fileExists(atPath: metadataURL.path) {
            let data = try Data(contentsOf: metadataURL)
            if !data.isEmpty {
                let dict = try JSONDecoder().decode([String: FileMetadata].self, from: data)
                try conn.withTransaction {
                    for metadata in dict.values {
                        try insertMetadataInternal(metadata)
                    }
                }
                let bakURL = metadataURL.appendingPathExtension("bak")
                try? FileManager.default.removeItem(at: bakURL)
                try? FileManager.default.moveItem(at: metadataURL, to: bakURL)
            } else {
                try? FileManager.default.removeItem(at: metadataURL)
            }
        }
        hasCheckedMigration = true
    }

    private func insertMetadataInternal(_ metadata: FileMetadata) throws {
        let sql = """
        INSERT OR REPLACE INTO sync_metadata (
            file_id, vault_id, name, parent_id, is_directory, sync_status,
            local_path, remote_path, size, local_modified_at, remote_modified_at,
            etag, download_progress, last_sync_time
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
        stmt.bindText(metadata.fileId, at: 1)
        stmt.bindOptionalText(vaultId, at: 2)
        stmt.bindText(metadata.name, at: 3)
        stmt.bindText(metadata.parentId, at: 4)
        stmt.bindBool(metadata.isDirectory, at: 5)
        stmt.bindText(metadata.syncStatus.rawValue, at: 6)
        stmt.bindOptionalText(metadata.localPath, at: 7)
        stmt.bindOptionalText(metadata.remotePath, at: 8)
        stmt.bindInt64(metadata.size, at: 9)
        stmt.bindOptionalDouble(metadata.localModifiedAt?.timeIntervalSince1970, at: 10)
        stmt.bindOptionalDouble(metadata.remoteModifiedAt?.timeIntervalSince1970, at: 11)
        stmt.bindOptionalText(metadata.etag, at: 12)
        stmt.bindDouble(metadata.downloadProgress, at: 13)
        stmt.bindOptionalDouble(metadata.lastSyncTime?.timeIntervalSince1970, at: 14)
        if stmt.step() != SQLITE_DONE {
            throw DatabaseError.stepFailed(sql: sql, code: 1, message: "Failed to persist file metadata")
        }
    }

    public func saveMetadata() {
        // SQLite writes commit synchronously with WAL; no whole-file rewrite needed.
    }

    public func updateMetadataPersistent(_ metadata: FileMetadata) throws {
        try checkMigrationIfNeeded()
        try conn.withTransaction {
            try insertMetadataInternal(metadata)
        }
    }

    public func updateMetadata(_ metadata: FileMetadata) {
        do { try updateMetadataPersistent(metadata) }
        catch { log(error) }
    }

    public func getMetadata(fileId: String) -> FileMetadata? {
        do {
            try checkMigrationIfNeeded()
            let altId = fileId.hasPrefix("/") ? String(fileId.dropFirst()) : "/\(fileId)"
            let sql = """
            SELECT file_id, vault_id, name, parent_id, is_directory, sync_status,
                   local_path, remote_path, size, local_modified_at, remote_modified_at,
                   etag, download_progress, last_sync_time
            FROM sync_metadata WHERE file_id = ? OR file_id = ? LIMIT 1;
            """
            let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
            stmt.bindText(fileId, at: 1)
            stmt.bindText(altId, at: 2)
            if stmt.step() == SQLITE_ROW {
                return parseMetadata(stmt: stmt)
            }
            return nil
        } catch {
            log(error)
            return nil
        }
    }

    public func getAllMetadata() -> [FileMetadata] {
        do {
            try checkMigrationIfNeeded()
            let sql = """
            SELECT file_id, vault_id, name, parent_id, is_directory, sync_status,
                   local_path, remote_path, size, local_modified_at, remote_modified_at,
                   etag, download_progress, last_sync_time
            FROM sync_metadata;
            """
            let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
            var list: [FileMetadata] = []
            while stmt.step() == SQLITE_ROW {
                if let meta = parseMetadata(stmt: stmt) {
                    list.append(meta)
                }
            }
            return list
        } catch {
            log(error)
            return []
        }
    }

    public func mutateMetadata(fileId: String, _ action: (inout FileMetadata) -> Void) throws {
        try checkMigrationIfNeeded()
        try conn.withTransaction {
            guard var metadata = getMetadata(fileId: fileId) else { return }
            action(&metadata)
            try insertMetadataInternal(metadata)
        }
    }

    public func removeMetadata(fileId: String) {
        do { try removeMetadataPersistent(fileId: fileId) }
        catch { log(error) }
    }

    func removeMetadataPersistent(fileId: String) throws {
        try checkMigrationIfNeeded()
        try conn.withTransaction {
            let altId = fileId.hasPrefix("/") ? String(fileId.dropFirst()) : "/\(fileId)"
            let sql = "DELETE FROM sync_metadata WHERE file_id = ? OR file_id = ?;"
            let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
            stmt.bindText(fileId, at: 1)
            stmt.bindText(altId, at: 2)
            _ = stmt.step()
        }
    }

    public func moveMetadata(from oldFileId: String, to newFileId: String, newParentId: String, newName: String, newRemotePath: String, fallbackStatus: SyncStatus) {
        do {
            try checkMigrationIfNeeded()
            try conn.withTransaction {
                let old = getMetadata(fileId: oldFileId)
                try removeMetadataPersistent(fileId: oldFileId)
                let updated = FileMetadata(
                    fileId: newFileId, name: newName, parentId: newParentId,
                    isDirectory: old?.isDirectory ?? false,
                    syncStatus: old?.syncStatus ?? fallbackStatus,
                    localPath: old?.localPath == nil ? nil : cachePath(for: newFileId),
                    remotePath: newRemotePath, size: old?.size ?? 0,
                    localModifiedAt: old?.localModifiedAt,
                    remoteModifiedAt: old?.remoteModifiedAt,
                    etag: old?.etag, downloadProgress: old?.downloadProgress ?? 0,
                    lastSyncTime: old?.lastSyncTime
                )
                try insertMetadataInternal(updated)
            }
        } catch { log(error) }
    }

    public func moveDirectoryMetadata(from oldDirId: String, to newDirId: String, newParentId: String, newName: String, newRemotePath: String) {
        do {
            try checkMigrationIfNeeded()
            try conn.withTransaction {
                let old = getMetadata(fileId: oldDirId)
                try removeMetadataPersistent(fileId: oldDirId)
                let updated = FileMetadata(
                    fileId: newDirId, name: newName, parentId: newParentId, isDirectory: true,
                    syncStatus: old?.syncStatus ?? .pendingMove, remotePath: newRemotePath,
                    localModifiedAt: old?.localModifiedAt,
                    remoteModifiedAt: old?.remoteModifiedAt,
                    etag: old?.etag, lastSyncTime: old?.lastSyncTime
                )
                try insertMetadataInternal(updated)

                let oldPrefix = oldDirId.hasSuffix("/") ? oldDirId : oldDirId + "/"
                let newPrefix = newDirId.hasSuffix("/") ? newDirId : newDirId + "/"
                let all = getAllMetadata()
                for child in all where child.fileId.hasPrefix(oldPrefix) {
                    try removeMetadataPersistent(fileId: child.fileId)
                    let newKey = newPrefix + child.fileId.dropFirst(oldPrefix.count)
                    let parent = child.parentId == oldDirId ? newDirId : Self.replacePrefix(child.parentId, oldPrefix, newPrefix)
                    let path = child.remotePath.map { Self.replacePrefix($0, oldPrefix, newPrefix) }
                    let movedChild = FileMetadata(
                        fileId: newKey, name: child.name, parentId: parent, isDirectory: child.isDirectory,
                        syncStatus: child.syncStatus,
                        localPath: child.localPath == nil ? nil : cachePath(for: newKey),
                        remotePath: path, size: child.size,
                        localModifiedAt: child.localModifiedAt, remoteModifiedAt: child.remoteModifiedAt,
                        etag: child.etag, downloadProgress: child.downloadProgress, lastSyncTime: child.lastSyncTime
                    )
                    try insertMetadataInternal(movedChild)
                }
            }
        } catch { log(error) }
    }

    public func removeDirectoryMetadata(forDirectoryPrefix dirPrefix: String) {
        let prefix = dirPrefix.hasSuffix("/") ? dirPrefix : dirPrefix + "/"
        do {
            try checkMigrationIfNeeded()
            try conn.withTransaction {
                let sql = "DELETE FROM sync_metadata WHERE file_id = ? OR file_id LIKE ?;"
                let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
                stmt.bindText(dirPrefix, at: 1)
                stmt.bindText("\(prefix)%", at: 2)
                _ = stmt.step()
            }
        } catch { log(error) }
    }

    public func getPendingSyncFiles() -> [FileMetadata] {
        do {
            try checkMigrationIfNeeded()
            let sql = """
            SELECT file_id, vault_id, name, parent_id, is_directory, sync_status,
                   local_path, remote_path, size, local_modified_at, remote_modified_at,
                   etag, download_progress, last_sync_time
            FROM sync_metadata
            WHERE sync_status != 'synced' AND sync_status != 'cloudOnly';
            """
            let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
            var list: [FileMetadata] = []
            while stmt.step() == SQLITE_ROW {
                if let meta = parseMetadata(stmt: stmt) {
                    list.append(meta)
                }
            }
            return list
        } catch {
            return []
        }
    }

    private func parseMetadata(stmt: SQLiteStatement) -> FileMetadata? {
        guard let status = SyncStatus(rawValue: stmt.columnText(at: 5)) else { return nil }
        return FileMetadata(
            fileId: stmt.columnText(at: 0),
            name: stmt.columnText(at: 2),
            parentId: stmt.columnText(at: 3),
            isDirectory: stmt.columnBool(at: 4),
            syncStatus: status,
            localPath: stmt.columnOptionalText(at: 6),
            remotePath: stmt.columnOptionalText(at: 7),
            size: stmt.columnInt64(at: 8),
            localModifiedAt: stmt.columnOptionalDouble(at: 9).map { Date(timeIntervalSince1970: $0) },
            remoteModifiedAt: stmt.columnOptionalDouble(at: 10).map { Date(timeIntervalSince1970: $0) },
            etag: stmt.columnOptionalText(at: 11),
            downloadProgress: stmt.columnDouble(at: 12),
            lastSyncTime: stmt.columnOptionalDouble(at: 13).map { Date(timeIntervalSince1970: $0) }
        )
    }

    private func cachePath(for fileId: String) -> String {
        let directory = CachePathLayout.directory(vaultId: vaultId).resolvingSymlinksInPath().standardized
        return CachePathLayout.localPath(fileId: fileId, cacheDirectory: directory).path
    }

    private static func replacePrefix(_ path: String, _ oldPrefix: String, _ newPrefix: String) -> String {
        guard path.hasPrefix(oldPrefix) else { return path }
        return newPrefix + path.dropFirst(oldPrefix.count)
    }

    private func log(_ error: Error) {
        Logger.shared.error(.sync, "Sync metadata database access failed: \(error.localizedDescription)")
    }
}
