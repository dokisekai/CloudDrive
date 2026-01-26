//
//  VFSDatabase.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  虚拟文件系统本地数据库
//

import Foundation
import SQLite3

/// VFS 本地数据库管理器
class VFSDatabase {
    private var db: OpaquePointer?
    private let dbPath: URL
    
    init() {
        // 使用 App Group 共享容器，确保主应用和 File Provider 扩展都能访问
        let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.net.aabg.CloudDrive")
        
        let appDir: URL
        if let sharedContainerURL = sharedContainerURL {
            // 使用 App Group 共享目录
            appDir = sharedContainerURL.appendingPathComponent(".CloudDrive", isDirectory: true)
            print("✅ 使用 App Group 共享容器")
        } else {
            // 回退到用户主目录（不推荐，File Provider 无法访问）
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            appDir = homeDir.appendingPathComponent(".CloudDrive", isDirectory: true)
            print("⚠️ App Group 不可用，回退到用户主目录")
        }
        
        // 确保目录存在
        do {
            try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true, attributes: nil)
            print("✅ 数据库目录: \(appDir.path)")
        } catch {
            print("❌ 创建数据库目录失败: \(error)")
        }
        
        self.dbPath = appDir.appendingPathComponent("vfs.db")
        print("📁 数据库路径: \(dbPath.path)")
    }
    
    deinit {
        close()
    }
    
    // MARK: - Database Management
    
    func initialize(vaultId: String, basePath: String) throws {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("💾 开始初始化数据库")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("   保险库ID: \(vaultId)")
        print("   基础路径: \(basePath)")
        
        do {
            // 如果数据库已存在，检查是否需要重新初始化
            if FileManager.default.fileExists(atPath: dbPath.path) {
                print("ℹ️ 数据库文件已存在")
                
                // 尝试打开并验证数据库
                do {
                    try open()
                    
                    // 检查保险库信息是否匹配
                    if let info = try? getVaultInfo(), info.vaultId == vaultId {
                        print("✅ 数据库已存在且保险库ID匹配，跳过初始化")
                        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                        print("✅ 数据库初始化完成（使用现有数据库）")
                        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                        return
                    }
                    
                    // 保险库ID不匹配，需要重新初始化
                    print("⚠️ 保险库ID不匹配，需要重新初始化")
                    close()
                    
                    // 使用安全的方式删除数据库
                    // 1. 先重命名旧数据库
                    let backupPath = dbPath.path + ".backup.\(Date().timeIntervalSince1970)"
                    try FileManager.default.moveItem(atPath: dbPath.path, toPath: backupPath)
                    print("✅ 旧数据库已备份到: \(backupPath)")
                    
                    // 2. 稍后删除备份（给其他进程时间关闭）
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                        try? FileManager.default.removeItem(atPath: backupPath)
                        print("🗑️ 已删除数据库备份")
                    }
                    
                } catch {
                    print("⚠️ 无法打开现有数据库: \(error.localizedDescription)")
                    print("   将创建新数据库")
                    close()
                }
            }
            
            try open()
            print("✅ 步骤 1/3: 数据库打开成功")
            
            try createTables()
            print("✅ 步骤 2/3: 数据表创建成功")
            
            try saveVaultInfo(vaultId: vaultId, basePath: basePath)
            print("✅ 步骤 3/3: 保险库信息保存成功")
            
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("✅ 数据库初始化完成")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        } catch {
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("❌ 数据库初始化失败")
            print("   错误: \(error.localizedDescription)")
            if let nsError = error as NSError? {
                print("   Domain: \(nsError.domain)")
                print("   Code: \(nsError.code)")
                print("   UserInfo: \(nsError.userInfo)")
            }
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            // 重新抛出原始错误，保留错误信息
            throw error
        }
    }
    
    func load(vaultId: String, basePath: String) throws {
        print("💾 加载数据库...")
        do {
            try open()
            print("✅ 数据库打开成功")
            
            guard let info = try getVaultInfo(), info.vaultId == vaultId else {
                print("❌ 保险库ID不匹配")
                throw VFSError.databaseError("保险库ID不匹配")
            }
            print("✅ 保险库信息验证成功")
        } catch {
            print("❌ 数据库加载失败: \(error)")
            throw VFSError.databaseError("数据库加载失败: \(error.localizedDescription)")
        }
    }
    
    private func open() throws {
        print("   🔓 打开数据库...")
        
        // 确保数据库目录存在
        let dbDir = dbPath.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dbDir.path) {
            do {
                try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
                print("   ✅ 创建数据库目录: \(dbDir.path)")
            } catch {
                print("   ❌ 创建数据库目录失败: \(error)")
                throw VFSError.databaseError("创建数据库目录失败: \(error.localizedDescription)")
            }
        }
        
        // 检查目录权限
        if !FileManager.default.isWritableFile(atPath: dbDir.path) {
            print("   ❌ 数据库目录不可写: \(dbDir.path)")
            throw VFSError.databaseError("数据库目录不可写: \(dbDir.path)")
        }
        
        let result = sqlite3_open(dbPath.path, &db)
        if result != SQLITE_OK {
            let errorMessage = db != nil ? String(cString: sqlite3_errmsg(db)) : "未知错误"
            print("   ❌ SQLite 打开失败: \(errorMessage) (错误码: \(result))")
            throw VFSError.databaseError("SQLite 打开失败: \(errorMessage) (错误码: \(result))")
        }
        
        print("   ✅ SQLite 数据库已打开")
    }
    
    private func close() {
        if db != nil {
            sqlite3_close(db)
            db = nil
            print("   🔒 数据库已关闭")
        }
    }
    
    private func createTables() throws {
        print("   📋 创建数据表...")
        
        let tables = [
            """
            CREATE TABLE IF NOT EXISTS vault_info (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                vault_id TEXT NOT NULL,
                base_path TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS directories (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                parent_id TEXT,
                encrypted_id TEXT NOT NULL,
                remote_path TEXT NOT NULL,
                created_at REAL NOT NULL,
                modified_at REAL NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS files (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                parent_id TEXT NOT NULL,
                size INTEGER NOT NULL,
                encrypted_name TEXT NOT NULL,
                remote_path TEXT NOT NULL,
                created_at REAL NOT NULL,
                modified_at REAL NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_directories_parent ON directories(parent_id);",
            "CREATE INDEX IF NOT EXISTS idx_files_parent ON files(parent_id);"
        ]
        
        for (index, sql) in tables.enumerated() {
            do {
                try execute(sql: sql)
                print("   ✅ 表/索引 \(index + 1)/\(tables.count) 创建成功")
            } catch {
                print("   ❌ 表/索引 \(index + 1) 创建失败")
                print("   SQL: \(sql)")
                throw error
            }
        }
    }
    
    private func execute(sql: String) throws {
        guard let db = db else {
            print("   ❌ 数据库未打开")
            throw VFSError.databaseError("数据库未打开")
        }
        
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        if prepareResult != SQLITE_OK {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            print("   ❌ SQL 准备失败: \(errorMessage) (错误码: \(prepareResult))")
            throw VFSError.databaseError("SQL 准备失败: \(errorMessage) (错误码: \(prepareResult))")
        }
        
        let stepResult = sqlite3_step(statement)
        if stepResult != SQLITE_DONE {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            print("   ❌ SQL 执行失败: \(errorMessage) (错误码: \(stepResult))")
            throw VFSError.databaseError("SQL 执行失败: \(errorMessage) (错误码: \(stepResult))")
        }
    }
    
    // MARK: - Vault Info
    
    private func saveVaultInfo(vaultId: String, basePath: String) throws {
        print("   💾 保存保险库信息...")
        
        guard let db = db else {
            print("   ❌ 数据库未打开")
            throw VFSError.databaseError("数据库未打开")
        }
        
        // 先清空旧数据
        do {
            try execute(sql: "DELETE FROM vault_info;")
            print("   ✅ 清空旧数据")
        } catch {
            print("   ⚠️ 清空旧数据失败（可能是首次创建）")
        }
        
        let sql = "INSERT INTO vault_info (vault_id, base_path, created_at) VALUES (?, ?, ?);"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        if prepareResult != SQLITE_OK {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            print("   ❌ 保存保险库信息准备失败: \(errorMessage)")
            throw VFSError.databaseError("保存保险库信息准备失败: \(errorMessage)")
        }
        
        sqlite3_bind_text(statement, 1, (vaultId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (basePath as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        
        let stepResult = sqlite3_step(statement)
        if stepResult != SQLITE_DONE {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            print("   ❌ 保存保险库信息执行失败: \(errorMessage) (错误码: \(stepResult))")
            throw VFSError.databaseError("保存保险库信息执行失败: \(errorMessage) (错误码: \(stepResult))")
        }
        
        print("   ✅ 保险库信息已保存")
    }
    
    public func getVaultInfo() throws -> (vaultId: String, basePath: String)? {
        guard let db = db else {
            throw VFSError.databaseError("数据库未打开")
        }
        
        let sql = "SELECT vault_id, base_path FROM vault_info LIMIT 1;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            print("❌ 获取保险库信息准备失败: \(errorMessage)")
            throw VFSError.databaseError("获取保险库信息准备失败: \(errorMessage)")
        }
        
        if sqlite3_step(statement) == SQLITE_ROW {
            let vaultId = String(cString: sqlite3_column_text(statement, 0))
            let basePath = String(cString: sqlite3_column_text(statement, 1))
            return (vaultId, basePath)
        }
        
        return nil
    }
    
    // MARK: - Directory Operations
    
    func insertDirectory(id: String, name: String, parentId: String?, encryptedId: String, remotePath: String) throws {
        guard let db = db else {
            throw VFSError.databaseError("数据库未打开")
        }
        
        let sql = """
        INSERT INTO directories (id, name, parent_id, encrypted_id, remote_path, created_at, modified_at)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            print("❌ 插入目录准备失败: \(errorMessage)")
            throw VFSError.databaseError("插入目录准备失败: \(errorMessage)")
        }
        
        let now = Date().timeIntervalSince1970
        sqlite3_bind_text(statement, 1, (id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (name as NSString).utf8String, -1, nil)
        if let parentId = parentId {
            sqlite3_bind_text(statement, 3, (parentId as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        sqlite3_bind_text(statement, 4, (encryptedId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 5, (remotePath as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 6, now)
        sqlite3_bind_double(statement, 7, now)
        
        if sqlite3_step(statement) != SQLITE_DONE {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            print("❌ 插入目录执行失败: \(errorMessage)")
            throw VFSError.databaseError("插入目录执行失败: \(errorMessage)")
        }
    }
    
    func getDirectory(id: String) throws -> VirtualDirectory? {
        guard let db = db else {
            throw VFSError.databaseError("数据库未打开")
        }
        
        let sql = "SELECT id, name, parent_id, encrypted_id, remote_path, modified_at FROM directories WHERE id = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            throw VFSError.databaseError("获取目录准备失败: \(errorMessage)")
        }
        
        sqlite3_bind_text(statement, 1, (id as NSString).utf8String, -1, nil)
        
        if sqlite3_step(statement) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(statement, 0))
            let name = String(cString: sqlite3_column_text(statement, 1))
            let parentId = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(statement, 2))
            let encryptedId = String(cString: sqlite3_column_text(statement, 3))
            let remotePath = String(cString: sqlite3_column_text(statement, 4))
            let modifiedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
            
            return VirtualDirectory(id: id, name: name, parentId: parentId, encryptedId: encryptedId, remotePath: remotePath, modifiedAt: modifiedAt)
        }
        
        return nil
    }
    
    func deleteDirectory(id: String) throws {
        guard let db = db else {
            throw VFSError.databaseError("数据库未打开")
        }
        
        let sql = "DELETE FROM directories WHERE id = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            throw VFSError.databaseError("删除目录准备失败: \(errorMessage)")
        }
        
        sqlite3_bind_text(statement, 1, (id as NSString).utf8String, -1, nil)
        
        if sqlite3_step(statement) != SQLITE_DONE {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            throw VFSError.databaseError("删除目录执行失败: \(errorMessage)")
        }
    }
    
    // MARK: - File Operations
    
    func insertFile(id: String, name: String, parentId: String, size: Int64, encryptedName: String, remotePath: String) throws {
        guard let db = db else {
            throw VFSError.databaseError("数据库未打开")
        }
        
        let sql = """
        INSERT INTO files (id, name, parent_id, size, encrypted_name, remote_path, created_at, modified_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            throw VFSError.databaseError("插入文件准备失败: \(errorMessage)")
        }
        
        let now = Date().timeIntervalSince1970
        sqlite3_bind_text(statement, 1, (id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (name as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (parentId as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(statement, 4, size)
        sqlite3_bind_text(statement, 5, (encryptedName as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 6, (remotePath as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 7, now)
        sqlite3_bind_double(statement, 8, now)
        
        if sqlite3_step(statement) != SQLITE_DONE {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            throw VFSError.databaseError("插入文件执行失败: \(errorMessage)")
        }
    }
    
    func getFile(id: String) throws -> VirtualFile? {
        guard let db = db else {
            throw VFSError.databaseError("数据库未打开")
        }
        
        let sql = "SELECT id, name, parent_id, size, encrypted_name, remote_path, modified_at FROM files WHERE id = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            throw VFSError.databaseError("获取文件准备失败: \(errorMessage)")
        }
        
        sqlite3_bind_text(statement, 1, (id as NSString).utf8String, -1, nil)
        
        if sqlite3_step(statement) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(statement, 0))
            let name = String(cString: sqlite3_column_text(statement, 1))
            let parentId = String(cString: sqlite3_column_text(statement, 2))
            let size = sqlite3_column_int64(statement, 3)
            let encryptedName = String(cString: sqlite3_column_text(statement, 4))
            let remotePath = String(cString: sqlite3_column_text(statement, 5))
            let modifiedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            
            return VirtualFile(id: id, name: name, parentId: parentId, size: size, encryptedName: encryptedName, remotePath: remotePath, modifiedAt: modifiedAt)
        }
        
        return nil
    }
    
    func deleteFile(id: String) throws {
        guard let db = db else {
            throw VFSError.databaseError("数据库未打开")
        }
        
        let sql = "DELETE FROM files WHERE id = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            throw VFSError.databaseError("删除文件准备失败: \(errorMessage)")
        }
        
        sqlite3_bind_text(statement, 1, (id as NSString).utf8String, -1, nil)
        
        if sqlite3_step(statement) != SQLITE_DONE {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            throw VFSError.databaseError("删除文件执行失败: \(errorMessage)")
        }
    }
    
    // MARK: - List Children
    
    func listChildren(parentId: String) throws -> [VirtualFileItem] {
        // 如果数据库未打开，尝试自动打开
        if db == nil {
            print("⚠️ 数据库未打开，尝试自动连接...")
            do {
                // 尝试打开现有数据库（不创建新的）
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: dbPath.path) {
                    try open()
                    print("✅ 数据库自动连接成功")
                } else {
                    print("ℹ️ 数据库文件不存在，返回空列表")
                    return []
                }
            } catch {
                print("❌ 数据库自动连接失败: \(error)")
                return []
            }
        }
        
        guard let db = db else {
            print("⚠️ 数据库未打开，返回空列表")
            return []
        }
        
        var items: [VirtualFileItem] = []
        
        // 获取子目录
        let dirSql = "SELECT id, name, modified_at FROM directories WHERE parent_id = ? OR (parent_id IS NULL AND ? = 'ROOT');"
        var dirStatement: OpaquePointer?
        defer { sqlite3_finalize(dirStatement) }
        
        if sqlite3_prepare_v2(db, dirSql, -1, &dirStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(dirStatement, 1, (parentId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(dirStatement, 2, (parentId as NSString).utf8String, -1, nil)
            
            while sqlite3_step(dirStatement) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(dirStatement, 0))
                let name = String(cString: sqlite3_column_text(dirStatement, 1))
                let modifiedAt = Date(timeIntervalSince1970: sqlite3_column_double(dirStatement, 2))
                
                items.append(VirtualFileItem(id: id, name: name, isDirectory: true, size: 0, modifiedAt: modifiedAt, parentId: parentId))
            }
        }
        
        // 获取文件
        let fileSql = "SELECT id, name, size, modified_at FROM files WHERE parent_id = ?;"
        var fileStatement: OpaquePointer?
        defer { sqlite3_finalize(fileStatement) }
        
        if sqlite3_prepare_v2(db, fileSql, -1, &fileStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(fileStatement, 1, (parentId as NSString).utf8String, -1, nil)
            
            while sqlite3_step(fileStatement) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(fileStatement, 0))
                let name = String(cString: sqlite3_column_text(fileStatement, 1))
                let size = sqlite3_column_int64(fileStatement, 2)
                let modifiedAt = Date(timeIntervalSince1970: sqlite3_column_double(fileStatement, 3))
                
                items.append(VirtualFileItem(id: id, name: name, isDirectory: false, size: size, modifiedAt: modifiedAt, parentId: parentId))
            }
        }
        
        return items
    }
}

// MARK: - Internal Models

struct VirtualDirectory {
    let id: String
    let name: String
    let parentId: String?
    let encryptedId: String
    let remotePath: String
    let modifiedAt: Date
}

struct VirtualFile {
    let id: String
    let name: String
    let parentId: String
    let size: Int64
    let encryptedName: String
    let remotePath: String
    let modifiedAt: Date
}