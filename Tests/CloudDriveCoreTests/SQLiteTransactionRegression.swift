import Foundation
import SQLite3
import CloudDriveCore

private enum TransactionFailure: Error { case assertion(String), injected }

func runSQLiteTransactionRegressionTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("transaction-regression-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let connection = SQLiteConnection(dbPath: root.appendingPathComponent("test.db"))
    defer { connection.close() }
    func require(_ value: Bool, _ message: String) throws {
        if !value { throw TransactionFailure.assertion(message) }
    }
    func count() throws -> Int64 {
        let statement = try SQLiteStatement(db: connection.getHandle(), sql: "SELECT COUNT(*) FROM records;")
        guard statement.step() == SQLITE_ROW else { throw TransactionFailure.assertion("Cannot count records") }
        return statement.columnInt64(at: 0)
    }
    try connection.execute(sql: "CREATE TABLE records (id INTEGER PRIMARY KEY, value TEXT); CREATE INDEX records_value ON records(value);")
    let index = try SQLiteStatement(db: connection.getHandle(), sql: "SELECT name FROM sqlite_master WHERE type='index' AND name='records_value';")
    try require(index.step() == SQLITE_ROW, "Complete schema script must create its index")
    try connection.withTransaction {
        try connection.execute(sql: "INSERT INTO records VALUES(1, 'outer-before');")
        do {
            try connection.withTransaction {
                try connection.execute(sql: "INSERT INTO records VALUES(2, 'inner');")
                throw TransactionFailure.injected
            }
        } catch TransactionFailure.injected { }
        try connection.execute(sql: "INSERT INTO records VALUES(3, 'outer-after');")
    }
    try require(try count() == 2, "Caught nested error must roll back only nested writes")
    let handle = try connection.getHandle()
    sqlite3_set_authorizer(handle, { _, action, first, _, _, _ in
        if action == SQLITE_TRANSACTION, let first, String(cString: first) == "COMMIT" { return SQLITE_DENY }
        return SQLITE_OK
    }, nil)
    var failed = false
    do {
        try connection.withTransaction { try connection.execute(sql: "INSERT INTO records VALUES(4, 'failed-commit');") }
    } catch { failed = true }
    sqlite3_set_authorizer(handle, nil, nil)
    try require(failed && sqlite3_get_autocommit(handle) == 1, "Failed COMMIT must leave no open transaction")
    try require(try count() == 2, "Failed COMMIT must roll back its content")
    try connection.withTransaction { try connection.execute(sql: "INSERT INTO records VALUES(5, 'next-commit');") }
    try require(try count() == 3, "Connection must remain usable after failed COMMIT")
    let value = "before\0after 中文"
    try connection.withTransaction {
        let insert = try SQLiteStatement(db: connection.getHandle(), sql: "INSERT INTO records VALUES(6, ?);")
        insert.bindText(value, at: 1)
        try require(insert.step() == SQLITE_DONE, "Text insertion failed")
    }
    let read = try SQLiteStatement(db: handle, sql: "SELECT value FROM records WHERE id = 6;")
    try require(read.step() == SQLITE_ROW && read.columnText(at: 0) == value, "Bound text must preserve embedded NUL")
    let poisoned = SQLiteConnection(dbPath: root.appendingPathComponent("poisoned.db"))
    try poisoned.execute(sql: "CREATE TABLE records(id INTEGER);")
    let poisonedHandle = try poisoned.getHandle()
    sqlite3_set_authorizer(poisonedHandle, { _, action, first, _, _, _ in
        if action == SQLITE_TRANSACTION, let first, ["COMMIT", "ROLLBACK"].contains(String(cString: first)) { return SQLITE_DENY }
        return SQLITE_OK
    }, nil)
    do { try poisoned.withTransaction { try poisoned.execute(sql: "INSERT INTO records VALUES(1);") } }
    catch { }
    var refused = false
    do { try poisoned.execute(sql: "INSERT INTO records VALUES(2);") } catch { refused = true }
    try require(refused && poisoned.rawHandle == nil, "Failed rollback must block further writes instead of pretending to commit")
    sqlite3_set_authorizer(poisonedHandle, nil, nil)
    poisoned.close()
    try poisoned.withTransaction { try poisoned.execute(sql: "INSERT INTO records VALUES(3);") }
    let repaired = try SQLiteStatement(db: poisoned.getHandle(), sql: "SELECT COUNT(*) FROM records;")
    try require(repaired.step() == SQLITE_ROW && repaired.columnInt64(at: 0) == 1, "Explicit reopening must discard the poisoned transaction")
    poisoned.close()
    print("✅ SQLite nested rollback, failed COMMIT recovery, full schema and text regressions passed")
}
