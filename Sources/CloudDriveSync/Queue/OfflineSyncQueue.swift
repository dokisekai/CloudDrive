import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CloudDrivePersistence
import SQLite3

/// High-performance SQLite-backed durable operation queue.
/// Each mutation executes an ACID row transaction with WAL concurrency,
/// completely avoiding full-file JSON serialization and write amplification.
public final class OfflineSyncQueue: @unchecked Sendable {
    let conn: SQLiteConnection
    let queueURL: URL
    let dbURL: URL
    let migrationLock = NSLock()
    var hasCheckedMigration = false
    var schemaError: Error?

    public var persistenceURL: URL { dbURL }

    public init(queueURL: URL = CloudDrivePaths.sharedDirectory.appendingPathComponent("sync_queue.json")) {
        self.queueURL = queueURL
        if queueURL.pathExtension == "db" {
            self.dbURL = queueURL
        } else {
            self.dbURL = queueURL.deletingPathExtension().appendingPathExtension("db")
        }
        self.conn = SQLiteConnection(dbPath: dbURL)
        ensureSchema()
    }



}
