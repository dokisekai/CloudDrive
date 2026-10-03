import Foundation
import CloudDriveContracts
import CloudDriveSupport
import SQLite3
import CloudDrivePersistence

extension Pan123DatabaseStore {
    // MARK: - Token Management (30 天持久化存储)
    
    /// 将获取到的 AccessToken 持久化至本地 SQLite 数据库
    public func saveToken(clientID: String, token: String, expiredAt: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        
        let db = try conn.getHandle()
        let sql = """
        INSERT INTO pan123_tokens (client_id, access_token, expired_at, updated_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(client_id) DO UPDATE SET
            access_token = excluded.access_token,
            expired_at = excluded.expired_at,
            updated_at = excluded.updated_at;
        """
        let stmt = try SQLiteStatement(db: db, sql: sql)
        stmt.bindText(clientID, at: 1)
        stmt.bindText(token, at: 2)
        stmt.bindDouble(expiredAt.timeIntervalSince1970, at: 3)
        stmt.bindDouble(Date().timeIntervalSince1970, at: 4)
        
        let rc = stmt.step()
        guard rc == SQLITE_DONE else {
            throw DatabaseError.stepFailed(sql: sql, code: rc, message: "Failed to persist 123pan token")
        }
    }
    
    /// 从数据库读取已持久化的有效 Token
    public func loadToken(clientID: String) throws -> (token: String, expiredAt: Date)? {
        lock.lock()
        defer { lock.unlock() }
        
        let db = try conn.getHandle()
        let sql = "SELECT access_token, expired_at FROM pan123_tokens WHERE client_id = ? LIMIT 1;"
        let stmt = try SQLiteStatement(db: db, sql: sql)
        stmt.bindText(clientID, at: 1)
        
        if stmt.step() == SQLITE_ROW {
            let token = stmt.columnText(at: 0)
            let expiredAtTimestamp = stmt.columnDouble(at: 1)
            let expiredAt = Date(timeIntervalSince1970: expiredAtTimestamp)
            return (token, expiredAt)
        }
        return nil
    }
    
    /// 删除指定 clientID 的持久化 Token
    public func deleteToken(clientID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        
        let db = try conn.getHandle()
        let sql = "DELETE FROM pan123_tokens WHERE client_id = ?;"
        let stmt = try SQLiteStatement(db: db, sql: sql)
        stmt.bindText(clientID, at: 1)
        _ = stmt.step()
    }
}
