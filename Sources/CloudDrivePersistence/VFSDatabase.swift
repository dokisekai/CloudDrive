import CloudDriveContracts
import CloudDriveSupport
//
//  VFSDatabase.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  Virtual File System Local Database (向后兼容门面，底层由模块化 Repositories 驱动)
//

import Foundation
import SQLite3

///// VFS Local Database Manager
public class VFSDatabase {
    public let connection: SQLiteConnection
    public let vaultInfoRepo: VaultInfoRepository
    public let directoryRepo: DirectoryRepository
    public let fileItemRepo: FileItemRepository
    public let vaultSettingsRepo: VaultSettingsRepository
    public let dbPath: URL
    
    public init(vaultId: String? = nil, directory: URL? = nil) {
        let appDir = directory ?? CloudDrivePaths.sharedDirectory
        let path: URL
        if let vid = vaultId, !vid.isEmpty {
            let folder = directory ?? CloudDrivePaths.vaultDirectory(for: vid)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            path = folder.appendingPathComponent("vfs.db")
            // Old databases are caches. Retain originals, rebuild under an unambiguous namespace.
        } else {
            path = appDir.appendingPathComponent("vfs.db")
        }
        self.dbPath = path
        let conn = SQLiteConnection(dbPath: path)
        self.connection = conn
        self.vaultInfoRepo = VaultInfoRepository(connection: conn)
        self.directoryRepo = DirectoryRepository(connection: conn)
        self.fileItemRepo = FileItemRepository(connection: conn)
        self.vaultSettingsRepo = VaultSettingsRepository(connection: conn)
        print("📁 Database path: \(path.path)")
    }
    
    deinit {
        close()
    }
    
    // MARK: - Database Management
    
    public func initialize(vaultId: String, basePath: String) throws {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("💾 Initializing database")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("   Vault ID: \(vaultId)")
        print("   Base path: \(basePath)")
        
        do {
            if FileManager.default.fileExists(atPath: dbPath.path) {
                print("ℹ️ Database file already exists")
                do {
                    try open()
                    if let info = try? getVaultInfo(), info.vaultId == vaultId {
                        print("✅ Database exists and vault ID matches, skipping initialization")
                        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                        print("✅ Database initialization completed (using existing database)")
                        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                        return
                    }
                    print("⚠️ Vault ID mismatch, reinitialization required")
                    close()
                    
                    let backupPath = dbPath.path + ".backup.\(Date().timeIntervalSince1970)"
                    try FileManager.default.moveItem(atPath: dbPath.path, toPath: backupPath)
                    print("✅ Old database backed up to: \(backupPath)")
                    
                } catch {
                    print("⚠️ Failed to open existing database: \(error.localizedDescription)")
                    print("   Creating new database")
                    close()
                    let backupPath = dbPath.path + ".corrupted.\(Date().timeIntervalSince1970)"
                    try FileManager.default.moveItem(atPath: dbPath.path, toPath: backupPath)
                }
            }
            
            try open()
            print("✅ Step 1/3: Database opened successfully")
            
            try createTables()
            print("✅ Step 2/3: Tables created successfully")
            
            try saveVaultInfo(vaultId: vaultId, basePath: basePath)
            print("✅ Step 3/3: Vault info saved successfully")
            
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("✅ Database initialization completed")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        } catch {
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("❌ Database initialization failed: \(error.localizedDescription)")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            throw error
        }
    }
    
    public func load(vaultId: String, basePath: String) throws {
        print("💾 Loading database...")
        do {
            try open()
            print("✅ Database opened successfully")
            
            guard let info = try getVaultInfo(), info.vaultId == vaultId else {
                print("❌ Vault ID mismatch")
                throw VFSError.databaseError("Vault ID mismatch")
            }
            print("✅ Vault info validated successfully")
        } catch {
            print("❌ Database load failed: \(error)")
            throw VFSError.databaseError("Database load failed: \(error.localizedDescription)")
        }
    }
    
    public func open() throws {
        print("   🔓 Opening database...")
        let dbDir = dbPath.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dbDir.path) {
            try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true, attributes: nil)
        }
        try connection.open()
        try? vaultSettingsRepo.ensureTableExists()
        print("   ✅ SQLite database opened (DELETE mode)")
    }
    
    public func close() {
        connection.close()
        print("   🔒 Database closed")
    }
    
    private func createTables() throws {
        print("   📋 Creating tables...")
        var count = 0
        let allTables: [DatabaseTable] = [.vaultInfo, .directories, .files, .vaultSettings]
        for table in allTables {
            for sql in table.createSchemaStatements {
                try connection.execute(sql: sql)
                count += 1
                print("   ✅ Table/index \(count) created successfully")
            }
        }
    }
    
    // MARK: - Vault Info
    
    private func saveVaultInfo(vaultId: String, basePath: String) throws {
        print("   💾 Saving vault info...")
        try vaultInfoRepo.saveVaultInfo(vaultId: vaultId, basePath: basePath)
        print("   ✅ Vault info saved")
    }
    
    public func getVaultInfo() throws -> (vaultId: String, basePath: String)? {
        try vaultInfoRepo.getVaultInfo()
    }
    
    // MARK: - Directory Operations
    
    public func insertDirectory(id: String, name: String, parentId: String?, encryptedId: String, remotePath: String, modifiedAt: Date? = nil) throws {
        try directoryRepo.insertDirectory(id: id, name: name, parentId: parentId, encryptedId: encryptedId, remotePath: remotePath, modifiedAt: modifiedAt)
    }
    
    public func getDirectory(id: String) throws -> VirtualDirectory? {
        try directoryRepo.getDirectory(id: id)
    }
    
    public func getAllDescendantFileIds(directoryId: String) -> [String] {
        directoryRepo.getAllDescendantFileIds(directoryId: directoryId)
    }
    
    public func deleteDirectory(id: String) throws {
        try directoryRepo.deleteDirectory(id: id)
    }
    
    public func moveDirectory(oldId: String, newId: String, newName: String, newParentId: String, newRemotePath: String) throws {
        try directoryRepo.moveDirectory(oldId: oldId, newId: newId, newName: newName, newParentId: newParentId, newRemotePath: newRemotePath)
    }
    
    // MARK: - File Operations
    
    public func insertFile(id: String, name: String, parentId: String, size: Int64, encryptedName: String, remotePath: String, modifiedAt: Date? = nil) throws {
        try fileItemRepo.insertFile(id: id, name: name, parentId: parentId, size: size, encryptedName: encryptedName, remotePath: remotePath, modifiedAt: modifiedAt)
    }
    
    public func getFile(id: String) throws -> VirtualFile? {
        try fileItemRepo.getFile(id: id)
    }
    
    public func deleteFile(id: String) throws {
        try fileItemRepo.deleteFile(id: id)
    }
    
    // MARK: - List Children
    
    public func listChildren(parentId: String) throws -> [VirtualFileItem] {
        try fileItemRepo.listChildren(parentId: parentId)
    }
    
    // MARK: - Vault Settings (加密库专属配置)
    
    /// 获取当前加密库持久化的忽略规则内容
    public func getIgnoreRules() -> String? {
        do {
            try open()
            return try vaultSettingsRepo.getIgnoreRules()
        } catch {
            return nil
        }
    }
    
    /// 设置当前加密库持久化的忽略规则内容
    public func setIgnoreRules(_ rules: String) throws {
        try open()
        try vaultSettingsRepo.setIgnoreRules(rules)
    }
    
    /// 获取任意加密库专属键值配置
    public func getVaultSetting(key: String) -> String? {
        do {
            try open()
            return try vaultSettingsRepo.get(key: key)
        } catch {
            return nil
        }
    }
    
    /// 设置任意加密库专属键值配置
    public func setVaultSetting(key: String, value: String) throws {
        try open()
        try vaultSettingsRepo.set(key: key, value: value)
    }
}