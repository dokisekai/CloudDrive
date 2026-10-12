import CloudDriveContracts
import CloudDriveSupport
//
//  SQLiteConnection.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  SQLite 原生安全连接包装 (支持惰性自动连接)
//

import Foundation
import SQLite3

/// SQLite 原生安全连接管理类
public final class SQLiteConnection: @unchecked Sendable {
    private var db: OpaquePointer?
    private var transactionFailure: Error?
    public let dbPath: URL
    private let lock = NSRecursiveLock()
    
    public init(dbPath: URL) {
        self.dbPath = dbPath
    }
    
    deinit {
        close()
    }
    
    /// 获取有效数据库句柄（如果未打开则自动连接）
    public func getHandle() throws -> OpaquePointer {
        lock.lock()
        defer { lock.unlock() }
        
        if let transactionFailure { throw transactionFailure }
        if let existing = db {
            return existing
        }
        
        try openInternal()
        
        guard let validDb = db else {
            throw DatabaseError.notOpened
        }
        return validDb
    }
    
    public var rawHandle: OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        guard transactionFailure == nil else { return nil }
        if let existing = db {
            return existing
        }
        try? openInternal()
        return db
    }
    
    public var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return db != nil
    }
    
    public func open() throws {
        lock.lock()
        defer { lock.unlock() }
        try openInternal()
    }
    
    private func openInternal() throws {
        if db != nil { return }
        
        let dbDir = dbPath.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dbDir.path) {
            try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true, attributes: nil)
        }
        
        let pathStr = dbPath.path
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(pathStr, &handle, flags, nil)
        
        guard result == SQLITE_OK, let validDb = handle else {
            let errMsg = handle != nil ? String(cString: sqlite3_errmsg(handle)) : "Unknown"
            if let h = handle { sqlite3_close(h) }
            throw DatabaseError.connectionFailed(path: pathStr, code: result, message: errMsg)
        }
        
        // Publish the handle only after every required setting succeeds.
        do {
            guard sqlite3_busy_timeout(validDb, 5_000) == SQLITE_OK else {
                throw DatabaseError.connectionFailed(path: pathStr, code: sqlite3_errcode(validDb), message: "Cannot configure database timeout")
            }
            for sql in ["PRAGMA journal_mode = WAL;", "PRAGMA synchronous = NORMAL;"] {
                var error: UnsafeMutablePointer<CChar>?
                let code = sqlite3_exec(validDb, sql, nil, nil, &error)
                let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(validDb))
                sqlite3_free(error)
                guard code == SQLITE_OK else {
                    throw DatabaseError.stepFailed(sql: sql, code: code, message: message)
                }
            }
            self.db = validDb
        } catch {
            sqlite3_close_v2(validDb)
            throw error
        }
    }

    private var transactionDepth = 0

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        // A reentrant caller cannot invalidate the handle held by its transaction.
        guard transactionDepth == 0 else { return }
        if let currentDb = db {
            // Outstanding read statements may still exist. close_v2 keeps their
            // handle alive until finalization instead of leaking a BUSY connection.
            sqlite3_close_v2(currentDb)
            self.db = nil
        }
        transactionFailure = nil
    }

    public func execute(sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let currentDb = try getHandle()
        var error: UnsafeMutablePointer<CChar>?
        // Execute the complete script; silently running only its first statement
        // previously skipped indexes and other schema initialization.
        let code = sqlite3_exec(currentDb, sql, nil, nil, &error)
        let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(currentDb))
        sqlite3_free(error)
        guard code == SQLITE_OK else {
            throw DatabaseError.stepFailed(sql: sql, code: code, message: message)
        }
    }

    public func withTransaction<T>(_ block: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        let handle = try getHandle()
        sqlite3_mutex_enter(sqlite3_db_mutex(handle))
        defer { sqlite3_mutex_leave(sqlite3_db_mutex(handle)) }
        let originalDepth = transactionDepth
        let savepoint = "clouddrive_nested_\(originalDepth)"
        if originalDepth == 0 {
            try execute(sql: "BEGIN IMMEDIATE TRANSACTION;")
        } else {
            try execute(sql: "SAVEPOINT \(savepoint);")
        }
        transactionDepth = originalDepth + 1
        do {
            let result = try block()
            if let transactionFailure { throw transactionFailure }
            // Keep ownership until COMMIT actually succeeds. A failed COMMIT
            // leaves SQLite's transaction open and must also be rolled back.
            if originalDepth == 0 { try execute(sql: "COMMIT;") }
            else { try execute(sql: "RELEASE SAVEPOINT \(savepoint);") }
            transactionDepth = originalDepth
            return result
        } catch {
            if originalDepth == 0 {
                // Bypass the poisoned wrapper to give the outer transaction a
                // final opportunity to recover a failed nested savepoint.
                let code = sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
                if sqlite3_get_autocommit(handle) != 0 { transactionFailure = nil }
                else { transactionFailure = DatabaseError.stepFailed(sql: "ROLLBACK", code: code, message: "Transaction recovery failed; reopen the connection") }
            } else {
                let rollbackCode = sqlite3_exec(handle, "ROLLBACK TO SAVEPOINT \(savepoint);", nil, nil, nil)
                let releaseCode = sqlite3_exec(handle, "RELEASE SAVEPOINT \(savepoint);", nil, nil, nil)
                if rollbackCode != SQLITE_OK || releaseCode != SQLITE_OK {
                    transactionFailure = DatabaseError.stepFailed(sql: "ROLLBACK TO SAVEPOINT", code: rollbackCode != SQLITE_OK ? rollbackCode : releaseCode, message: "Nested transaction recovery failed")
                }
            }
            transactionDepth = originalDepth
            throw error
        }
    }
}
