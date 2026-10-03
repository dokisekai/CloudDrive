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
        
        self.db = validDb
        
        // Configure WAL mode for concurrent readers and writers across App and extension processes.
        var err: UnsafeMutablePointer<CChar>?
        sqlite3_exec(validDb, "PRAGMA journal_mode = WAL;", nil, nil, &err)
        sqlite3_free(err)
        sqlite3_exec(validDb, "PRAGMA synchronous = NORMAL;", nil, nil, &err)
        sqlite3_free(err)
        sqlite3_busy_timeout(validDb, 5_000)
    }
    
    private var transactionDepth = 0

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        transactionDepth = 0
        if let currentDb = db {
            sqlite3_close(currentDb)
            self.db = nil
        }
    }
    
    public func execute(sql: String) throws {
        let currentDb = try getHandle()
        
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        let prepareResult = sqlite3_prepare_v2(currentDb, sql, -1, &statement, nil)
        if prepareResult != SQLITE_OK {
            let errMsg = String(cString: sqlite3_errmsg(currentDb))
            throw DatabaseError.prepareFailed(sql: sql, code: prepareResult, message: errMsg)
        }
        
        let stepResult = sqlite3_step(statement)
        if stepResult != SQLITE_DONE && stepResult != SQLITE_ROW {
            let errMsg = String(cString: sqlite3_errmsg(currentDb))
            throw DatabaseError.stepFailed(sql: sql, code: stepResult, message: errMsg)
        }
    }
    
    public func withTransaction<T>(_ block: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let db = try? getHandle() else { throw DatabaseError.notOpened }
        sqlite3_mutex_enter(sqlite3_db_mutex(db))
        defer { sqlite3_mutex_leave(sqlite3_db_mutex(db)) }
        if transactionDepth == 0 {
            try execute(sql: "BEGIN IMMEDIATE TRANSACTION;")
        }
        transactionDepth += 1
        do {
            let result = try block()
            transactionDepth -= 1
            if transactionDepth == 0 {
                try execute(sql: "COMMIT;")
            }
            return result
        } catch {
            if transactionDepth == 1 {
                try? execute(sql: "ROLLBACK;")
            }
            transactionDepth = max(0, transactionDepth - 1)
            throw error
        }
    }
}
