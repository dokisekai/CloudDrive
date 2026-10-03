import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CloudDrivePersistence
import SQLite3

extension OfflineSyncQueue {
    public func saveSyncQueue() {
        // SQLite transactions commit synchronously with WAL; no whole-file rewrite needed.
    }

    @discardableResult
    public func enqueuePersistent(_ operation: SyncOperation, expectedETag: String? = nil, vaultId: String? = nil) throws -> SyncQueueItem {
        try checkMigrationIfNeeded()
        let item = SyncQueueItem(operation: operation, expectedETag: expectedETag, vaultId: vaultId)
        try conn.withTransaction {
            try insertItemInternal(item)
        }
        return item
    }

    @discardableResult
    public func enqueue(_ operation: SyncOperation, vaultId: String? = nil) -> SyncQueueItem {
        do { return try enqueuePersistent(operation, vaultId: vaultId) }
        catch {
            Logger.shared.error(.sync, "Cannot persist sync operation: \(error.localizedDescription)")
            return SyncQueueItem(operation: operation, vaultId: vaultId)
        }
    }

    public func hasPendingUpload(fileId: String) -> Bool {
        let altId = fileId.hasPrefix("/") ? String(fileId.dropFirst()) : "/\(fileId)"
        return getAllItems().contains { item in
            switch item.operation {
            case .upload(let id, _, _), .encryptedUpload(let id, _, _, _, _):
                return id == fileId || id == altId
            default:
                return false
            }
        }
    }

    public func removePendingUploads(for fileId: String) {
        do {
            try checkMigrationIfNeeded()
            let altId = fileId.hasPrefix("/") ? String(fileId.dropFirst()) : "/\(fileId)"
            try conn.withTransaction {
                let sql = "SELECT id, operation_json FROM sync_queue WHERE file_id = ? OR file_id = ?;"
                let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
                stmt.bindText(fileId, at: 1)
                stmt.bindText(altId, at: 2)
                var idsToDelete: [String] = []
                while stmt.step() == SQLITE_ROW {
                    let itemId = stmt.columnText(at: 0)
                    let json = stmt.columnText(at: 1)
                    if let data = json.data(using: .utf8),
                       let op = try? JSONDecoder().decode(SyncOperation.self, from: data) {
                        switch op {
                        case .upload, .encryptedUpload:
                            idsToDelete.append(itemId)
                        default:
                            break
                        }
                    }
                }
                for id in idsToDelete {
                    let delSQL = "DELETE FROM sync_queue WHERE id = ?;"
                    let delStmt = try SQLiteStatement(db: try conn.getHandle(), sql: delSQL)
                    delStmt.bindText(id, at: 1)
                    _ = delStmt.step()
                }
            }
        } catch { log(error) }
    }

    public func hasPendingOperation(fileId: String) -> Bool {
        do {
            try checkMigrationIfNeeded()
            let altId = fileId.hasPrefix("/") ? String(fileId.dropFirst()) : "/\(fileId)"
            let sql = "SELECT 1 FROM sync_queue WHERE file_id = ? OR file_id = ? LIMIT 1;"
            let stmt = try SQLiteStatement(db: try conn.getHandle(), sql: sql)
            stmt.bindText(fileId, at: 1)
            stmt.bindText(altId, at: 2)
            return stmt.step() == SQLITE_ROW
        } catch {
            return false
        }
    }
}
