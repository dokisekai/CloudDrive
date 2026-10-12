import Foundation
import SQLite3
import CloudDrivePersistence

/// Optional acceleration only. An unreadable index never authorizes a copy.
final class CacheContentIndex {
    struct Entry {
        let fileId: String
        let hash: String
        let etag: String?
        let generation: Double?
        let inode: Int64
        let modified: Double
        let size: Int64
    }
    private let connection: SQLiteConnection
    private var schemaError: Error?
    init(url: URL) {
        connection = SQLiteConnection(dbPath: url)
        do {
            try connection.execute(sql: """
            CREATE TABLE IF NOT EXISTS content_index(file_id TEXT PRIMARY KEY, hash TEXT NOT NULL, etag TEXT, generation REAL, inode INTEGER NOT NULL, modified REAL NOT NULL, size INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS idx_content_index_hash ON content_index(hash, size);
            """)
        } catch { schemaError = error }
    }
    private func key(_ id: String) -> String { id.hasPrefix("/") ? String(id.dropFirst()) : id }
    private func check() throws { if let schemaError { throw schemaError } }
    func record(fileId: String, hash: String, etag: String?, generation: Double?, url: URL) throws {
        try check()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let inode = (attributes[.systemFileNumber] as? NSNumber)?.int64Value,
              let modified = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.int64Value else { throw CocoaError(.fileReadUnknown) }
        try connection.withTransaction {
            let statement = try SQLiteStatement(db: connection.getHandle(), sql: "INSERT OR REPLACE INTO content_index VALUES(?, ?, ?, ?, ?, ?, ?);")
            statement.bindText(key(fileId), at: 1)
            statement.bindText(hash, at: 2)
            statement.bindOptionalText(etag, at: 3)
            if let generation { statement.bindDouble(generation, at: 4) } else { statement.bindNull(at: 4) }
            statement.bindInt64(inode, at: 5)
            statement.bindDouble(modified.timeIntervalSince1970, at: 6)
            statement.bindInt64(size, at: 7)
            guard statement.step() == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
        }
    }
    func get(_ fileId: String) throws -> Entry? {
        try check()
        let statement = try SQLiteStatement(db: connection.getHandle(), sql: "SELECT file_id, hash, etag, generation, inode, modified, size FROM content_index WHERE file_id = ?;")
        statement.bindText(key(fileId), at: 1)
        let result = statement.step()
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw CocoaError(.fileReadUnknown) }
        return parse(statement)
    }
    func candidates(hash: String, size: Int64) throws -> [Entry] {
        try check()
        let statement = try SQLiteStatement(db: connection.getHandle(), sql: "SELECT file_id, hash, etag, generation, inode, modified, size FROM content_index WHERE hash = ? AND size = ? LIMIT 32;")
        statement.bindText(hash, at: 1)
        statement.bindInt64(size, at: 2)
        var entries: [Entry] = []
        while true {
            let result = statement.step()
            if result == SQLITE_DONE { return entries }
            guard result == SQLITE_ROW else { throw CocoaError(.fileReadUnknown) }
            entries.append(parse(statement))
        }
    }
    private func parse(_ statement: SQLiteStatement) -> Entry {
        Entry(fileId: statement.columnText(at: 0), hash: statement.columnText(at: 1), etag: statement.columnOptionalText(at: 2), generation: statement.columnOptionalDouble(at: 3), inode: statement.columnInt64(at: 4), modified: statement.columnDouble(at: 5), size: statement.columnInt64(at: 6))
    }
    func matches(_ entry: Entry, url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return (attributes[.systemFileNumber] as? NSNumber)?.int64Value == entry.inode &&
            (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 == entry.modified &&
            (attributes[.size] as? NSNumber)?.int64Value == entry.size
    }
    func remove(_ fileId: String) throws {
        try check()
        let statement = try SQLiteStatement(db: connection.getHandle(), sql: "DELETE FROM content_index WHERE file_id = ?;")
        statement.bindText(key(fileId), at: 1)
        guard statement.step() == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
    }
}
