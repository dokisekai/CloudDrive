import Foundation
import CloudDriveContracts
import CloudDrivePersistence
import SQLite3

struct SyncCompletionReceipt: Codable {
    var item: SyncQueueItem
    var etag: String?
    var remotePath: String?
    var replacement: FileMetadata?
    var stagedPath: String?
    var deleted: Bool
    var metadataFallback: FileMetadata?
}

struct SyncCommitEntry: Codable {
    enum Kind: String, Codable { case enqueue, completion }
    var id: String
    var kind: Kind
    var item: SyncQueueItem?
    var metadataBefore: FileMetadata?
    var metadataPrepared: FileMetadata?
    var receipt: SyncCompletionReceipt?
}

extension OfflineSyncQueue {
    func persistCommitEntry(_ entry: SyncCommitEntry) throws {
        try checkMigrationIfNeeded()
        try conn.withTransaction {
            let statement = try SQLiteStatement(db: try conn.getHandle(), sql: "INSERT INTO sync_commit_journal(id, entry_json) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET entry_json = excluded.entry_json;")
            statement.bindText(entry.id, at: 1)
            statement.bindText(String(decoding: try JSONEncoder().encode(entry), as: UTF8.self), at: 2)
            guard statement.step() == SQLITE_DONE else { throw SyncError.operationFailed("Cannot persist sync commit intent") }
        }
    }

    func pendingCommitEntries() throws -> [SyncCommitEntry] {
        try checkMigrationIfNeeded()
        let statement = try SQLiteStatement(db: try conn.getHandle(), sql: "SELECT entry_json FROM sync_commit_journal ORDER BY rowid;")
        var entries: [SyncCommitEntry] = []
        while try hasRow(statement) {
            entries.append(try JSONDecoder().decode(SyncCommitEntry.self, from: Data(statement.columnText(at: 0).utf8)))
        }
        return entries
    }

    func hasCommitEntry(id: String) throws -> Bool {
        try checkMigrationIfNeeded()
        let statement = try SQLiteStatement(db: try conn.getHandle(), sql: "SELECT 1 FROM sync_commit_journal WHERE id = ?;")
        statement.bindText(id, at: 1)
        return try hasRow(statement)
    }

    func removeCommitEntry(id: String) throws {
        let statement = try SQLiteStatement(db: try conn.getHandle(), sql: "DELETE FROM sync_commit_journal WHERE id = ?;")
        statement.bindText(id, at: 1)
        guard statement.step() == SQLITE_DONE else { throw SyncError.operationFailed("Cannot finish sync commit intent") }
    }

    func finalizeEnqueue(_ item: SyncQueueItem, entryId: String) throws {
        try checkMigrationIfNeeded()
        try conn.withTransaction {
            try insertItemInternal(item)
            try removeCommitEntry(id: entryId)
        }
    }
}
