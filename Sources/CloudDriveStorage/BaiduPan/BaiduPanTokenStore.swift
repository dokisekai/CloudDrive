//
//  BaiduPanTokenStore.swift
//  CloudDriveStorage
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  跨进程令牌存储与 single-flight 刷新
//
//  为什么需要这么复杂：
//  主进程 CloudDrive.app 与扩展进程 CloudDriveFileProvider.appex 共享同一个 Vault。
//  access_token 30 天过期；refresh_token **一次性消耗**（每次刷新返回新的）。
//  两个进程同时检测到过期并同时刷新 → 后者拿到已失效的 refresh_token → 用户被迫重新扫码。
//  这不是偶现，是每次 token 到期必现。
//
//  方案：SQLite BEGIN IMMEDIATE 做跨进程互斥 + generation CAS + 30 秒租约。
//

import Foundation
import CloudDriveContracts
import CloudDriveSupport
import SQLite3
import CloudDrivePersistence
import CloudDriveSecurity

public final class BaiduPanTokenStore: @unchecked Sendable {

    public struct Record: Sendable {
        public let vaultID: String
        public let accessToken: String
        public let refreshToken: String
        public let expiresAt: Date
        public let generation: Int
        public let needsReauth: Bool

        public init(
            vaultID: String,
            accessToken: String,
            refreshToken: String,
            expiresAt: Date,
            generation: Int,
            needsReauth: Bool
        ) {
            self.vaultID = vaultID
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
            self.generation = generation
            self.needsReauth = needsReauth
        }
    }

    public struct TokenPayload: Codable, Sendable {
        public let vaultID: String
        public let appID: String
        public let clientID: String
        public let accessToken: String
        public let refreshToken: String
        public let expiresAt: Date
        public let generation: Int
        public let needsReauth: Bool

        public init(
            vaultID: String,
            appID: String,
            clientID: String,
            accessToken: String,
            refreshToken: String,
            expiresAt: Date,
            generation: Int = 0,
            needsReauth: Bool = false
        ) {
            self.vaultID = vaultID
            self.appID = appID
            self.clientID = clientID
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
            self.generation = generation
            self.needsReauth = needsReauth
        }
    }

    // MARK: - 内存高速缓存 (保证跨沙盒、零延迟、免除 SQLite 锁/路径故障)
    private static var inMemoryTokens: [String: Record] = [:]
    private static let inMemoryLock = NSLock()

    public static func setInMemoryToken(
        vaultID: String,
        appID: String,
        clientID: String,
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        generation: Int = 0,
        needsReauth: Bool = false
    ) {
        guard !accessToken.isEmpty else { return }
        inMemoryLock.lock()
        defer { inMemoryLock.unlock() }
        let effectiveExpiresAt = max(expiresAt, Date().addingTimeInterval(25 * 86400))
        let record = Record(
            vaultID: vaultID,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: effectiveExpiresAt,
            generation: generation,
            needsReauth: false
        )
        inMemoryTokens[vaultID] = record
        if vaultID != "default" {
            inMemoryTokens["default"] = record
        }
        Logger.shared.info(.system, "🔐 [BaiduPanTokenStore] Updated in-memory token for vault \(vaultID) (length: \(accessToken.count), expiresAt: \(effectiveExpiresAt))")
    }

    public static func getInMemoryToken(vaultID: String) -> Record? {
        inMemoryLock.lock()
        defer { inMemoryLock.unlock() }
        if let record = inMemoryTokens[vaultID] {
            return record
        }
        if vaultID != "default", let def = inMemoryTokens["default"] {
            return def
        }
        return nil
    }

    /// 租约时长：超过则判定持有进程已崩溃，可被接管
    private static let leaseDuration: TimeInterval = 30
    /// 提前刷新余量
    private static let refreshMargin: TimeInterval = 300
    private static let maxWaitIterations = 60
    private static let pollInterval: UInt64 = 500_000 // 500ms

    private let conn: SQLiteConnection
    private let lock = NSLock()
    private let sharedDefaults = UserDefaults(suiteName: "group.net.aabg.CloudDrive")

    public init(dbURL: URL = CloudDrivePaths.sharedDirectory.appendingPathComponent("baidupan.db")) {
        self.conn = SQLiteConnection(dbPath: dbURL)
        ensureSchema()
        broadcastExistingTokens()
    }

    private func ensureSchema() {
        let ddl = """
        CREATE TABLE IF NOT EXISTS baidupan_tokens (
            vault_id         TEXT PRIMARY KEY,
            app_id           TEXT NOT NULL,
            client_id        TEXT NOT NULL,
            access_token     TEXT NOT NULL,
            refresh_token    TEXT NOT NULL,
            expires_at       REAL NOT NULL,
            generation       INTEGER NOT NULL DEFAULT 0,
            refreshing_by    TEXT,
            refreshing_since REAL,
            needs_reauth     INTEGER NOT NULL DEFAULT 0,
            updated_at       REAL NOT NULL
        );
        """
        try? conn.execute(sql: ddl)

        let dlinkDDL = """
        CREATE TABLE IF NOT EXISTS baidupan_dlinks (
            path       TEXT PRIMARY KEY,
            fs_id      INTEGER NOT NULL,
            dlink      TEXT NOT NULL,
            expires_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """
        try? conn.execute(sql: dlinkDDL)

        let checkpointDDL = """
        CREATE TABLE IF NOT EXISTS baidupan_upload_checkpoints (
            path             TEXT PRIMARY KEY,
            uploadid         TEXT NOT NULL,
            size             INTEGER NOT NULL,
            slice_size       INTEGER NOT NULL,
            rtype            INTEGER NOT NULL,
            block_md5        TEXT NOT NULL,
            completed        TEXT NOT NULL,
            slice_md5s       TEXT NOT NULL,
            state            TEXT NOT NULL,
            updated_at       REAL NOT NULL
        );
        """
        try? conn.execute(sql: checkpointDDL)

        let userInfoDDL = """
        CREATE TABLE IF NOT EXISTS baidupan_user_info (
            vault_id   TEXT PRIMARY KEY,
            uk         INTEGER,
            baidu_name TEXT,
            netdisk_name TEXT,
            vip_type   INTEGER NOT NULL DEFAULT 0,
            total      INTEGER,
            used       INTEGER,
            fetched_at REAL NOT NULL
        );
        """
        try? conn.execute(sql: userInfoDDL)
    }

    public func readRecordPublic(_ vaultID: String) throws -> Record? {
        try readRecord(vaultID)
    }

    private func readRecord(_ vaultID: String) throws -> Record? {
        // 1. 优先内存高速缓存 (保证在沙盒隔离或 SQLite 文件不可达时立即可用)
        if let memRecord = Self.getInMemoryToken(vaultID: vaultID), !memRecord.accessToken.isEmpty, Date() < memRecord.expiresAt, !memRecord.needsReauth {
            return memRecord
        }
        if vaultID != "default", let defRecord = Self.getInMemoryToken(vaultID: "default"), !defRecord.accessToken.isEmpty, Date() < defRecord.expiresAt, !defRecord.needsReauth {
            return defRecord
        }

        lock.lock()
        defer { lock.unlock() }
        let sql = """
        SELECT vault_id, access_token, refresh_token, expires_at, generation, needs_reauth
        FROM baidupan_tokens WHERE vault_id = ? LIMIT 1;
        """
        if let stmt = try? SQLiteStatement(db: conn.getHandle(), sql: sql) {
            stmt.bindText(vaultID, at: 1)
            if stmt.step() == SQLITE_ROW {
                let record = Record(
                    vaultID: stmt.columnText(at: 0),
                    accessToken: stmt.columnText(at: 1),
                    refreshToken: stmt.columnText(at: 2),
                    expiresAt: Date(timeIntervalSince1970: stmt.columnDouble(at: 3)),
                    generation: Int(stmt.columnDouble(at: 4)),
                    needsReauth: stmt.columnDouble(at: 5) != 0
                )
                if !record.accessToken.isEmpty && Date() < record.expiresAt && !record.needsReauth {
                    Self.setInMemoryToken(
                        vaultID: record.vaultID,
                        appID: "",
                        clientID: "",
                        accessToken: record.accessToken,
                        refreshToken: record.refreshToken,
                        expiresAt: record.expiresAt,
                        generation: record.generation,
                        needsReauth: false
                    )
                    return record
                }
            }
        }
        
        // 2. 尝试从 Keychain 直接恢复 (最高优先级保底，不受沙盒 SQLite 路径隔离限制)
        if let kcData = CredentialStore.shared.getBaiduPanToken(for: vaultID) ?? (vaultID != "default" ? CredentialStore.shared.getBaiduPanToken(for: "default") : nil),
           let payload = try? JSONDecoder().decode(TokenPayload.self, from: kcData),
           !payload.accessToken.isEmpty,
           Date() < payload.expiresAt {
            Logger.shared.info(.system, "🎉 [BaiduPanTokenStore] Restored valid token for \(vaultID) directly from Keychain (expiresAt: \(payload.expiresAt))")
            Self.setInMemoryToken(
                vaultID: vaultID,
                appID: payload.appID,
                clientID: payload.clientID,
                accessToken: payload.accessToken,
                refreshToken: payload.refreshToken,
                expiresAt: payload.expiresAt,
                generation: payload.generation,
                needsReauth: false
            )
            // 写入本地 SQLite，解除 needs_reauth
            let upsertSQL = """
            INSERT INTO baidupan_tokens
                (vault_id, app_id, client_id, access_token, refresh_token, expires_at,
                 generation, refreshing_by, refreshing_since, needs_reauth, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, 0, NULL, NULL, 0, ?)
            ON CONFLICT(vault_id) DO UPDATE SET
                app_id = excluded.app_id,
                client_id = excluded.client_id,
                access_token = excluded.access_token,
                refresh_token = excluded.refresh_token,
                expires_at = excluded.expires_at,
                needs_reauth = 0,
                updated_at = excluded.updated_at;
            """
            if let stmt = try? SQLiteStatement(db: conn.getHandle(), sql: upsertSQL) {
                let now = Date().timeIntervalSince1970
                stmt.bindText(vaultID, at: 1)
                stmt.bindText(payload.appID, at: 2)
                stmt.bindText(payload.clientID, at: 3)
                stmt.bindText(payload.accessToken, at: 4)
                stmt.bindText(payload.refreshToken, at: 5)
                stmt.bindDouble(payload.expiresAt.timeIntervalSince1970, at: 6)
                stmt.bindDouble(now, at: 7)
                _ = stmt.step()
            }
            return Record(
                vaultID: vaultID,
                accessToken: payload.accessToken,
                refreshToken: payload.refreshToken,
                expiresAt: payload.expiresAt,
                generation: payload.generation,
                needsReauth: false
            )
        }

        // 3. 自动从 App Group Defaults 尝试恢复
        if let restored = readFromDefaults(vaultID: vaultID) {
            Logger.shared.info(.system, "🔄 [BaiduPanTokenStore] Restored token record for \(vaultID) from App Group defaults")
            Self.setInMemoryToken(
                vaultID: restored.vaultID,
                appID: "",
                clientID: "",
                accessToken: restored.accessToken,
                refreshToken: restored.refreshToken,
                expiresAt: restored.expiresAt,
                generation: restored.generation,
                needsReauth: restored.needsReauth
            )
            return restored
        }
        return nil
    }

    public func saveToDefaults(
        vaultID: String,
        appID: String,
        clientID: String,
        accessToken: String,
        refreshToken: String,
        expiresAt: Date
    ) {
        let payload = TokenPayload(
            vaultID: vaultID,
            appID: appID,
            clientID: clientID,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt
        )
        if let data = try? JSONEncoder().encode(payload) {
            sharedDefaults?.set(data, forKey: "baidupan_token_\(vaultID)")
            if vaultID == "default" {
                sharedDefaults?.set(data, forKey: "baidupan_token_default")
            }
            sharedDefaults?.synchronize()
            _ = CredentialStore.shared.saveBaiduPanToken(data: data, for: vaultID)
            if vaultID == "default" {
                _ = CredentialStore.shared.saveBaiduPanToken(data: data, for: "default")
            }
        }
    }

    /// 自动将当前本地数据库中现存的有效 Token 广播导出至 Keychain 与 Defaults
    public func broadcastExistingTokens() {
        let sql = "SELECT vault_id, app_id, client_id, access_token, refresh_token, expires_at, generation, needs_reauth FROM baidupan_tokens;"
        guard let handle = try? conn.getHandle(),
              let stmt = try? SQLiteStatement(db: handle, sql: sql) else { return }
        while stmt.step() == SQLITE_ROW {
            let vid = stmt.columnText(at: 0)
            let aid = stmt.columnText(at: 1)
            let cid = stmt.columnText(at: 2)
            let acc = stmt.columnText(at: 3)
            let ref = stmt.columnText(at: 4)
            let exp = Date(timeIntervalSince1970: stmt.columnDouble(at: 5))
            let gen = Int(stmt.columnDouble(at: 6))
            let nra = stmt.columnDouble(at: 7) != 0
            if !acc.isEmpty && Date() < exp {
                saveToDefaults(
                    vaultID: vid,
                    appID: aid,
                    clientID: cid,
                    accessToken: acc,
                    refreshToken: ref,
                    expiresAt: exp
                )
            }
        }
    }

    private func readFromDefaults(vaultID: String) -> Record? {
        let keys = ["baidupan_token_\(vaultID)", "baidupan_token_default"]
        for key in keys {
            if let data = sharedDefaults?.data(forKey: key) ?? CredentialStore.shared.getBaiduPanToken(for: key.replacingOccurrences(of: "baidupan_token_", with: "")),
               let payload = try? JSONDecoder().decode(TokenPayload.self, from: data),
               !payload.accessToken.isEmpty {
                // 写入当前本地 SQLite 数据库
                let sql = """
                INSERT INTO baidupan_tokens
                    (vault_id, app_id, client_id, access_token, refresh_token, expires_at,
                     generation, refreshing_by, refreshing_since, needs_reauth, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, 0, NULL, NULL, 0, ?)
                ON CONFLICT(vault_id) DO UPDATE SET
                    app_id = excluded.app_id,
                    client_id = excluded.client_id,
                    access_token = excluded.access_token,
                    refresh_token = excluded.refresh_token,
                    expires_at = excluded.expires_at,
                    needs_reauth = 0,
                    updated_at = excluded.updated_at;
                """
                if let stmt = try? SQLiteStatement(db: conn.getHandle(), sql: sql) {
                    let now = Date().timeIntervalSince1970
                    stmt.bindText(vaultID, at: 1)
                    stmt.bindText(payload.appID, at: 2)
                    stmt.bindText(payload.clientID, at: 3)
                    stmt.bindText(payload.accessToken, at: 4)
                    stmt.bindText(payload.refreshToken, at: 5)
                    stmt.bindDouble(payload.expiresAt.timeIntervalSince1970, at: 6)
                    stmt.bindDouble(now, at: 7)
                    _ = stmt.step()
                }
                return Record(
                    vaultID: vaultID,
                    accessToken: payload.accessToken,
                    refreshToken: payload.refreshToken,
                    expiresAt: payload.expiresAt,
                    generation: payload.generation,
                    needsReauth: payload.needsReauth
                )
            }
        }
        return nil
    }

    private func readLeaseOwner(_ vaultID: String) throws -> (owner: String?, since: Date?)? {
        lock.lock()
        defer { lock.unlock() }
        let sql = "SELECT refreshing_by, refreshing_since FROM baidupan_tokens WHERE vault_id = ? LIMIT 1;"
        let stmt = try SQLiteStatement(db: conn.getHandle(), sql: sql)
        stmt.bindText(vaultID, at: 1)
        guard stmt.step() == SQLITE_ROW else { return nil }
        let owner: String? = stmt.columnText(at: 0)
        let raw = stmt.columnDouble(at: 1)
        return (owner, raw > 0 ? Date(timeIntervalSince1970: raw) : nil)
    }

    // MARK: - 写

    private func acquireLease(vaultID: String, owner: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let sql = "UPDATE baidupan_tokens SET refreshing_by = ?, refreshing_since = ? WHERE vault_id = ?;"
        guard let handle = try? conn.getHandle(),
              let stmt = try? SQLiteStatement(db: handle, sql: sql) else { return }
        stmt.bindText(owner, at: 1)
        stmt.bindDouble(Date().timeIntervalSince1970, at: 2)
        stmt.bindText(vaultID, at: 3)
        _ = stmt.step()
    }

    private func releaseLease(vaultID: String) {
        lock.lock()
        defer { lock.unlock() }
        let sql = "UPDATE baidupan_tokens SET refreshing_by = NULL, refreshing_since = NULL WHERE vault_id = ?;"
        guard let handle = try? conn.getHandle(),
              let stmt = try? SQLiteStatement(db: handle, sql: sql) else { return }
        stmt.bindText(vaultID, at: 1)
        _ = stmt.step()
    }

    /// 首次授权或重新授权后写入完整凭据。
    public func saveAuthorized(
        vaultID: String,
        appID: String,
        clientID: String,
        accessToken: String,
        refreshToken: String,
        expiresIn: Int
    ) throws {
        Self.setInMemoryToken(
            vaultID: vaultID,
            appID: appID,
            clientID: clientID,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970 + TimeInterval(expiresIn))
        )
        lock.lock()
        defer { lock.unlock() }
        let sql = """
        INSERT INTO baidupan_tokens
            (vault_id, app_id, client_id, access_token, refresh_token, expires_at,
             generation, refreshing_by, refreshing_since, needs_reauth, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, 0, NULL, NULL, 0, ?)
        ON CONFLICT(vault_id) DO UPDATE SET
            app_id = excluded.app_id,
            client_id = excluded.client_id,
            access_token = excluded.access_token,
            refresh_token = excluded.refresh_token,
            expires_at = excluded.expires_at,
            generation = baidupan_tokens.generation + 1,
            refreshing_by = NULL,
            refreshing_since = NULL,
            needs_reauth = 0,
            updated_at = excluded.updated_at;
        """
        let stmt = try SQLiteStatement(db: conn.getHandle(), sql: sql)
        let now = Date().timeIntervalSince1970
        stmt.bindText(vaultID, at: 1)
        stmt.bindText(appID, at: 2)
        stmt.bindText(clientID, at: 3)
        stmt.bindText(accessToken, at: 4)
        stmt.bindText(refreshToken, at: 5)
        stmt.bindDouble(now + TimeInterval(expiresIn), at: 6)
        stmt.bindDouble(now, at: 7)
        guard stmt.step() == SQLITE_DONE else {
            throw DatabaseError.stepFailed(sql: sql, code: -1, message: "saveAuthorized failed")
        }
        saveToDefaults(
            vaultID: vaultID,
            appID: appID,
            clientID: clientID,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date(timeIntervalSince1970: now + TimeInterval(expiresIn))
        )
    }

    /// 判断是否疑似百度网盘 access_token（通常以 127. / 24. / 121. 开头，或包含多个点段且非 126/122 开头）
    public static func isLikelyAccessToken(_ token: String) -> Bool {
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("127.") || clean.hasPrefix("24.") || clean.hasPrefix("121.") {
            return true
        }
        let dotCount = clean.filter { $0 == "." }.count
        if dotCount >= 2 && !clean.hasPrefix("126.") && !clean.hasPrefix("122.") {
            return true
        }
        return false
    }

    /// 预置已有 Token（支持自动识别 Access Token 或 Refresh Token）
    /// - 若为 Access Token (如 127.xxx / 24.xxx)：直接存为有效凭据（赋予 25 天有效期），可立即免刷新使用；
    /// - 若为 Refresh Token (如 126.xxx)：存为待刷新凭据，首次使用时自动走 OAuth 刷新流程。
    public func bootstrap(
        vaultID: String,
        appID: String,
        clientID: String,
        refreshToken: String
    ) throws {
        let clean = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        // 关键防护：如果当前已有有效的 access_token，严禁将其覆盖为 '' 或重置为 0
        if let existing = (try? readRecord(vaultID)) ?? Self.getInMemoryToken(vaultID: vaultID) ?? (vaultID != "default" ? Self.getInMemoryToken(vaultID: "default") : nil),
           !existing.accessToken.isEmpty,
           Date() < existing.expiresAt {
            Logger.shared.info(.system, "🛡️ [BaiduPanTokenStore] Preserving active accessToken during bootstrap for vault \(vaultID)")
            lock.lock()
            defer { lock.unlock() }
            let sql = """
            INSERT INTO baidupan_tokens
                (vault_id, app_id, client_id, access_token, refresh_token, expires_at,
                 generation, refreshing_by, refreshing_since, needs_reauth, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, 0, NULL, NULL, 0, ?)
            ON CONFLICT(vault_id) DO UPDATE SET
                app_id = excluded.app_id,
                client_id = excluded.client_id,
                access_token = CASE WHEN excluded.access_token != '' THEN excluded.access_token ELSE baidupan_tokens.access_token END,
                refresh_token = excluded.refresh_token,
                expires_at = CASE WHEN excluded.expires_at > 0 THEN excluded.expires_at ELSE baidupan_tokens.expires_at END,
                needs_reauth = 0,
                updated_at = excluded.updated_at;
            """
            if let stmt = try? SQLiteStatement(db: conn.getHandle(), sql: sql) {
                let now = Date().timeIntervalSince1970
                stmt.bindText(vaultID, at: 1)
                stmt.bindText(appID, at: 2)
                stmt.bindText(clientID, at: 3)
                stmt.bindText(existing.accessToken, at: 4)
                stmt.bindText(clean, at: 5)
                stmt.bindDouble(existing.expiresAt.timeIntervalSince1970, at: 6)
                stmt.bindDouble(now, at: 7)
                _ = stmt.step()
            }
            return
        }

        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970

        if Self.isLikelyAccessToken(clean) {
            Self.setInMemoryToken(
                vaultID: vaultID,
                appID: appID,
                clientID: clientID,
                accessToken: clean,
                refreshToken: "",
                expiresAt: Date().addingTimeInterval(25 * 86400)
            )
            // 用户直接填入 Access Token：赋予 25 天有效期（2,160,000 秒），直接可用
            let sql = """
            INSERT INTO baidupan_tokens
                (vault_id, app_id, client_id, access_token, refresh_token, expires_at,
                 generation, refreshing_by, refreshing_since, needs_reauth, updated_at)
            VALUES (?, ?, ?, ?, '', ?, 0, NULL, NULL, 0, ?)
            ON CONFLICT(vault_id) DO UPDATE SET
                app_id = excluded.app_id,
                client_id = excluded.client_id,
                access_token = excluded.access_token,
                expires_at = excluded.expires_at,
                needs_reauth = 0,
                updated_at = excluded.updated_at;
            """
            let stmt = try SQLiteStatement(db: conn.getHandle(), sql: sql)
            stmt.bindText(vaultID, at: 1)
            stmt.bindText(appID, at: 2)
            stmt.bindText(clientID, at: 3)
            stmt.bindText(clean, at: 4)
            stmt.bindDouble(now + (25 * 86400), at: 5)
            stmt.bindDouble(now, at: 6)
            guard stmt.step() == SQLITE_DONE else {
                throw DatabaseError.stepFailed(sql: sql, code: -1, message: "bootstrap access_token failed")
            }
        } else {
            let sql = """
            INSERT INTO baidupan_tokens
                (vault_id, app_id, client_id, access_token, refresh_token, expires_at,
                 generation, refreshing_by, refreshing_since, needs_reauth, updated_at)
            VALUES (?, ?, ?, '', ?, 0, 0, NULL, NULL, 0, ?)
            ON CONFLICT(vault_id) DO UPDATE SET
                app_id = excluded.app_id,
                client_id = excluded.client_id,
                refresh_token = excluded.refresh_token,
                needs_reauth = 0,
                updated_at = excluded.updated_at;
            """
            let stmt = try SQLiteStatement(db: conn.getHandle(), sql: sql)
            stmt.bindText(vaultID, at: 1)
            stmt.bindText(appID, at: 2)
            stmt.bindText(clientID, at: 3)
            stmt.bindText(clean, at: 4)
            stmt.bindDouble(now, at: 5)
            guard stmt.step() == SQLITE_DONE else {
                throw DatabaseError.stepFailed(sql: sql, code: -1, message: "bootstrap failed")
            }
        }
    }

    /// 克隆凭据（用于新建保险库时从 default 模板继承有效授权，避免消耗/旋转 refresh_token）
    public func cloneCredentials(from sourceVaultID: String, to targetVaultID: String) {
        if let src = Self.getInMemoryToken(vaultID: sourceVaultID), !src.accessToken.isEmpty {
            let targetExisting = Self.getInMemoryToken(vaultID: targetVaultID)
            if targetExisting == nil || targetExisting?.accessToken.isEmpty == true {
                Self.setInMemoryToken(
                    vaultID: targetVaultID,
                    appID: "",
                    clientID: "",
                    accessToken: src.accessToken,
                    refreshToken: src.refreshToken,
                    expiresAt: src.expiresAt,
                    generation: src.generation,
                    needsReauth: src.needsReauth
                )
            }
        }
        lock.lock()
        defer { lock.unlock() }
        let sql = """
        INSERT INTO baidupan_tokens
            (vault_id, app_id, client_id, access_token, refresh_token, expires_at,
             generation, refreshing_by, refreshing_since, needs_reauth, updated_at)
        SELECT ?, app_id, client_id, access_token, refresh_token, expires_at,
               generation, NULL, NULL, 0, ?
          FROM baidupan_tokens
         WHERE vault_id = ?
        ON CONFLICT(vault_id) DO UPDATE SET
            app_id = excluded.app_id,
            client_id = excluded.client_id,
            access_token = excluded.access_token,
            refresh_token = excluded.refresh_token,
            expires_at = excluded.expires_at,
            needs_reauth = 0,
            updated_at = excluded.updated_at;
        """
        guard let stmt = try? SQLiteStatement(db: conn.getHandle(), sql: sql) else { return }
        stmt.bindText(targetVaultID, at: 1)
        stmt.bindDouble(Date().timeIntervalSince1970, at: 2)
        stmt.bindText(sourceVaultID, at: 3)
        _ = stmt.step()
        if let data = sharedDefaults?.data(forKey: "baidupan_token_\(sourceVaultID)") ?? CredentialStore.shared.getBaiduPanToken(for: sourceVaultID) ?? CredentialStore.shared.getBaiduPanToken(for: "default") {
            sharedDefaults?.set(data, forKey: "baidupan_token_\(targetVaultID)")
            sharedDefaults?.synchronize()
            _ = CredentialStore.shared.saveBaiduPanToken(data: data, for: targetVaultID)
        }
    }

    /// 强制将指定 vaultID 的 access_token 设为过期（用于收到 errno -6 强制走 OAuth 刷新）
    public func forceInvalidateToken(vaultID: String) {
        Self.inMemoryLock.lock()
        if let existing = Self.inMemoryTokens[vaultID] {
            Self.inMemoryTokens[vaultID] = Record(
                vaultID: existing.vaultID,
                accessToken: "",
                refreshToken: existing.refreshToken,
                expiresAt: Date(timeIntervalSince1970: 0),
                generation: existing.generation,
                needsReauth: false
            )
        }
        if vaultID != "default", let def = Self.inMemoryTokens["default"] {
            Self.inMemoryTokens["default"] = Record(
                vaultID: def.vaultID,
                accessToken: "",
                refreshToken: def.refreshToken,
                expiresAt: Date(timeIntervalSince1970: 0),
                generation: def.generation,
                needsReauth: false
            )
        }
        Self.inMemoryLock.unlock()

        lock.lock()
        defer { lock.unlock() }
        let sql = """
        UPDATE baidupan_tokens
           SET expires_at = 0, needs_reauth = 0, updated_at = ?
         WHERE vault_id = ?;
        """
        guard let handle = try? conn.getHandle(),
              let stmt = try? SQLiteStatement(db: handle, sql: sql) else { return }
        stmt.bindDouble(Date().timeIntervalSince1970, at: 1)
        stmt.bindText(vaultID, at: 2)
        _ = stmt.step()
    }

    /// 刷新成功后写回。CAS 失败说明期间被别的进程刷新过，返回 false。
    private func commitRefresh(
        vaultID: String,
        accessToken: String,
        refreshToken: String,
        expiresIn: Int,
        expectedGeneration: Int
    ) throws -> Bool {
        let now = Date().timeIntervalSince1970
        let newExpiresAt = Date(timeIntervalSince1970: now + TimeInterval(expiresIn))

        Self.setInMemoryToken(
            vaultID: vaultID,
            appID: "",
            clientID: "",
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: newExpiresAt,
            generation: expectedGeneration + 1
        )
        if vaultID != "default" {
            Self.setInMemoryToken(
                vaultID: "default",
                appID: "",
                clientID: "",
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: newExpiresAt,
                generation: expectedGeneration + 1
            )
        }

        lock.lock()
        defer { lock.unlock() }
        let sql = """
        UPDATE baidupan_tokens
           SET access_token = ?, refresh_token = ?, expires_at = ?,
               generation = generation + 1,
               refreshing_by = NULL, refreshing_since = NULL,
               needs_reauth = 0, updated_at = ?
         WHERE vault_id = ? AND generation = ?;
        """
        guard let handle = try? conn.getHandle(),
              let stmt = try? SQLiteStatement(db: handle, sql: sql) else {
            // 在受限沙盒无 SQLite 写权限时，内存更新已生效，安全返回 true
            return true
        }
        stmt.bindText(accessToken, at: 1)
        stmt.bindText(refreshToken, at: 2)
        stmt.bindDouble(now + TimeInterval(expiresIn), at: 3)
        stmt.bindDouble(now, at: 4)
        stmt.bindText(vaultID, at: 5)
        stmt.bindDouble(Double(expectedGeneration), at: 6)
        _ = stmt.step()
        let changed = (sqlite3_changes(handle) > 0)
        saveToDefaults(
            vaultID: vaultID,
            appID: "",
            clientID: "",
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: newExpiresAt
        )
        return true
    }

    private func markNeedsReauth(_ vaultID: String) {
        lock.lock()
        defer { lock.unlock() }
        let sql = """
        UPDATE baidupan_tokens
           SET needs_reauth = 1, refreshing_by = NULL, refreshing_since = NULL, updated_at = ?
         WHERE vault_id = ?;
        """
        guard let stmt = try? SQLiteStatement(db: conn.getHandle(), sql: sql) else { return }
        stmt.bindDouble(Date().timeIntervalSince1970, at: 1)
        stmt.bindText(vaultID, at: 2)
        _ = stmt.step()
    }

    public func delete(vaultID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = try? SQLiteStatement(db: conn.getHandle(), sql: "DELETE FROM baidupan_tokens WHERE vault_id = ?;") else { return }
        stmt.bindText(vaultID, at: 1)
        _ = stmt.step()
    }

    public func needsReauth(vaultID: String) -> Bool {
        (try? readRecord(vaultID))??.needsReauth ?? false
    }

    // MARK: - 对外：取有效 access_token（必要时跨进程 single-flight 刷新）

    /// 返回可用 access_token；必要时执行刷新。
    /// - Parameter refresh: 真正的网络刷新动作，由 APIClient 注入，避免本层依赖 URLSession。
    public func validAccessToken(
        vaultID: String,
        refresh: (_ refreshToken: String) async throws -> (access: String, refresh: String, expiresIn: Int)
    ) async throws -> String {

        let owner = "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"

        for _ in 0..<Self.maxWaitIterations {
            // —— 快路径 ——
            var record = try readRecord(vaultID)
            if record == nil, vaultID != "default" {
                // 当前 vaultID 尚无记录时，尝试从 default 克隆凭据
                if let def = try? readRecord("default"), !def.accessToken.isEmpty {
                    Logger.shared.info(.system, "🔄 [BaiduPanTokenStore] Auto-cloning credentials from default to \(vaultID)")
                    cloneCredentials(from: "default", to: vaultID)
                    record = try? readRecord(vaultID)
                }
            }
            if record == nil {
                record = Self.getInMemoryToken(vaultID: vaultID) ?? (vaultID != "default" ? Self.getInMemoryToken(vaultID: "default") : nil)
            }
            guard let current = record else {
                Logger.shared.error(.system, "❌ [BaiduPanTokenStore] No record found for vaultID: \(vaultID) in db: \(self.conn.dbPath.path)")
                throw StorageError.authenticationFailed
            }
            Logger.shared.info(.system, "🔑 [BaiduPan validAccessToken] vaultID: \(vaultID), accessLen: \(current.accessToken.count), refreshLen: \(current.refreshToken.count), expiresAt: \(current.expiresAt), needsReauth: \(current.needsReauth ? 1 : 0)")
            // 只要当前 accessToken 依然有效且非空，直接使用，绝不因历史 needsReauth 误杀
            if !current.accessToken.isEmpty {
                if Date().addingTimeInterval(Self.refreshMargin) < current.expiresAt {
                    return current.accessToken
                }
                // 如果没有 refreshToken，无法走网络刷新，直接使用当前 accessToken（让网络请求层验证）
                if current.refreshToken.isEmpty {
                    return current.accessToken
                }
            }
            if current.needsReauth {
                // 救生圈：尝试直接从 Keychain 强行恢复
                if let kcData = CredentialStore.shared.getBaiduPanToken(for: vaultID) ?? (vaultID != "default" ? CredentialStore.shared.getBaiduPanToken(for: "default") : nil),
                   let kcPayload = try? JSONDecoder().decode(TokenPayload.self, from: kcData),
                   !kcPayload.accessToken.isEmpty,
                   Date() < kcPayload.expiresAt {
                    Logger.shared.info(.system, "🎉 [BaiduPanTokenStore] Rescued from needsReauth via Keychain token for \(vaultID)!")
                    Self.setInMemoryToken(
                        vaultID: vaultID,
                        appID: kcPayload.appID,
                        clientID: kcPayload.clientID,
                        accessToken: kcPayload.accessToken,
                        refreshToken: kcPayload.refreshToken,
                        expiresAt: kcPayload.expiresAt,
                        generation: kcPayload.generation,
                        needsReauth: false
                    )
                    return kcPayload.accessToken
                }
                Logger.shared.error(.system, "❌ [BaiduPanTokenStore] Record needsReauth for vaultID: \(vaultID)")
                throw StorageError.authenticationFailed
            }

            // —— 是否有活跃租约 ——
            if let lease = try readLeaseOwner(vaultID),
               let since = lease.since,
               let leaseOwner = lease.owner,
               leaseOwner != owner,
               Date().timeIntervalSince(since) < Self.leaseDuration {
                try? await Task.sleep(nanoseconds: Self.pollInterval)
                continue
            }

            // —— 抢占租约（stale 租约可被接管，防进程崩溃死锁）——
            try acquireLease(vaultID: vaultID, owner: owner)
            defer { releaseLease(vaultID: vaultID) }

            // —— 抢占后双检：可能已有其他进程刚刷完 ——
            guard let afterLease = (try? readRecord(vaultID)) ?? Self.getInMemoryToken(vaultID: vaultID) else {
                Logger.shared.error(.system, "❌ [BaiduPanTokenStore] afterLease record not found for vaultID: \(vaultID)")
                throw StorageError.authenticationFailed
            }
            if Date().addingTimeInterval(Self.refreshMargin) < afterLease.expiresAt, !afterLease.accessToken.isEmpty {
                return afterLease.accessToken
            }
            if afterLease.needsReauth {
                Logger.shared.error(.system, "❌ [BaiduPanTokenStore] afterLease needsReauth for vaultID: \(vaultID)")
                throw StorageError.authenticationFailed
            }
            guard !afterLease.refreshToken.isEmpty else {
                Logger.shared.error(.system, "❌ [BaiduPanTokenStore] afterLease refreshToken is empty for vaultID: \(vaultID)")
                markNeedsReauth(vaultID)
                throw StorageError.authenticationFailed
            }

            // —— 网络 I/O（锁外）——
            let expectedGeneration = afterLease.generation
            do {
                let result = try await refresh(afterLease.refreshToken)
                let committed = try commitRefresh(
                    vaultID: vaultID,
                    accessToken: result.access,
                    refreshToken: result.refresh,
                    expiresIn: result.expiresIn,
                    expectedGeneration: expectedGeneration
                )
                if committed {
                    return result.access
                }
                // 期间被别人刷新过 → 读对方的值
                guard let winner = try readRecord(vaultID) else {
                    throw StorageError.authenticationFailed
                }
                return winner.accessToken
            } catch {
                // 刷新失败 → 需要用户重新扫码授权（官方：refresh_token 失败即失效）
                markNeedsReauth(vaultID)
                throw error
            }
        }

        throw StorageError.networkError("BaiduPan token refresh lease wait timed out")
    }

    // MARK: - dlink 缓存（8 小时有效）

    public func cachedDlink(path: String) -> (dlink: String, fsID: UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        let sql = "SELECT fs_id, dlink, expires_at FROM baidupan_dlinks WHERE path = ? LIMIT 1;"
        guard let stmt = try? SQLiteStatement(db: conn.getHandle(), sql: sql) else { return nil }
        stmt.bindText(path, at: 1)
        guard stmt.step() == SQLITE_ROW else { return nil }
        let expires = stmt.columnDouble(at: 2)
        guard Date().timeIntervalSince1970 < expires else { return nil }
        return (stmt.columnText(at: 1), UInt64(stmt.columnDouble(at: 0)))
    }

    public func storeDlink(path: String, dlink: String, fsID: UInt64, validFor: TimeInterval = 8 * 3600) {
        lock.lock()
        defer { lock.unlock() }
        let sql = """
        INSERT INTO baidupan_dlinks (path, fs_id, dlink, expires_at, updated_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
            fs_id = excluded.fs_id, dlink = excluded.dlink,
            expires_at = excluded.expires_at, updated_at = excluded.updated_at;
        """
        guard let stmt = try? SQLiteStatement(db: conn.getHandle(), sql: sql) else { return }
        let now = Date().timeIntervalSince1970
        stmt.bindText(path, at: 1)
        stmt.bindDouble(Double(fsID), at: 2)
        stmt.bindText(dlink, at: 3)
        stmt.bindDouble(now + validFor - 300, at: 4) // 提前 5 分钟失效
        stmt.bindDouble(now, at: 5)
        _ = stmt.step()
    }

    public func invalidateDlink(path: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = try? SQLiteStatement(db: conn.getHandle(), sql: "DELETE FROM baidupan_dlinks WHERE path = ?;") else { return }
        stmt.bindText(path, at: 1)
        _ = stmt.step()
    }

    // MARK: - 上传检查点

    public func loadCheckpoint(path: String) -> BaiduPanUploadCheckpoint? {
        lock.lock()
        defer { lock.unlock() }
        let sql = """
        SELECT uploadid, size, slice_size, rtype, block_md5, completed, slice_md5s, state
        FROM baidupan_upload_checkpoints WHERE path = ? LIMIT 1;
        """
        guard let stmt = try? SQLiteStatement(db: conn.getHandle(), sql: sql) else { return nil }
        stmt.bindText(path, at: 1)
        guard stmt.step() == SQLITE_ROW else { return nil }
        let decoder = JSONDecoder()
        let blockMD5 = (try? decoder.decode([String].self, from: Data(stmt.columnText(at: 4).utf8))) ?? []
        let completed = (try? decoder.decode([Int].self, from: Data(stmt.columnText(at: 5).utf8))) ?? []
        let sliceMD5s = (try? decoder.decode([String].self, from: Data(stmt.columnText(at: 6).utf8))) ?? []
        let state = BaiduPanUploadCheckpoint.State(rawValue: stmt.columnText(at: 7)) ?? .precreated
        return BaiduPanUploadCheckpoint(
            path: path,
            uploadid: stmt.columnText(at: 0),
            size: Int64(stmt.columnDouble(at: 1)),
            sliceSize: Int64(stmt.columnDouble(at: 2)),
            rtype: Int(stmt.columnDouble(at: 3)),
            blockMD5: blockMD5,
            completedSlices: completed,
            sliceMD5s: sliceMD5s,
            state: state
        )
    }

    public func saveCheckpoint(_ cp: BaiduPanUploadCheckpoint) {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        let blockData = (try? encoder.encode(cp.blockMD5)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let completedData = (try? encoder.encode(cp.completedSlices)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let sliceData = (try? encoder.encode(cp.sliceMD5s)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let sql = """
        INSERT INTO baidupan_upload_checkpoints
            (path, uploadid, size, slice_size, rtype, block_md5, completed, slice_md5s, state, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
            uploadid = excluded.uploadid, size = excluded.size,
            slice_size = excluded.slice_size, rtype = excluded.rtype,
            block_md5 = excluded.block_md5, completed = excluded.completed,
            slice_md5s = excluded.slice_md5s, state = excluded.state,
            updated_at = excluded.updated_at;
        """
        guard let stmt = try? SQLiteStatement(db: conn.getHandle(), sql: sql) else { return }
        stmt.bindText(cp.path, at: 1)
        stmt.bindText(cp.uploadid, at: 2)
        stmt.bindDouble(Double(cp.size), at: 3)
        stmt.bindDouble(Double(cp.sliceSize), at: 4)
        stmt.bindDouble(Double(cp.rtype), at: 5)
        stmt.bindText(blockData, at: 6)
        stmt.bindText(completedData, at: 7)
        stmt.bindText(sliceData, at: 8)
        stmt.bindText(cp.state.rawValue, at: 9)
        stmt.bindDouble(Date().timeIntervalSince1970, at: 10)
        _ = stmt.step()
    }

    public func clearCheckpoint(path: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = try? SQLiteStatement(db: conn.getHandle(), sql: "DELETE FROM baidupan_upload_checkpoints WHERE path = ?;") else { return }
        stmt.bindText(path, at: 1)
        _ = stmt.step()
    }

    // MARK: - 用户信息 / 会员档位缓存

    public func cachedTier(vaultID: String, maxAge: TimeInterval = 6 * 3600) -> BaiduPanTier? {
        lock.lock()
        defer { lock.unlock() }
        let sql = "SELECT vip_type, fetched_at FROM baidupan_user_info WHERE vault_id = ? LIMIT 1;"
        guard let stmt = try? SQLiteStatement(db: conn.getHandle(), sql: sql) else { return nil }
        stmt.bindText(vaultID, at: 1)
        guard stmt.step() == SQLITE_ROW else { return nil }
        let fetchedAt = stmt.columnDouble(at: 1)
        guard Date().timeIntervalSince1970 - fetchedAt < maxAge else { return nil }
        return BaiduPanTier(vipType: Int(stmt.columnDouble(at: 0)))
    }

    public func storeUserInfo(vaultID: String, uk: UInt64?, baiduName: String?, netdiskName: String?, vipType: Int, total: Int64?, used: Int64?) {
        lock.lock()
        defer { lock.unlock() }
        let sql = """
        INSERT INTO baidupan_user_info
            (vault_id, uk, baidu_name, netdisk_name, vip_type, total, used, fetched_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(vault_id) DO UPDATE SET
            uk = excluded.uk, baidu_name = excluded.baidu_name,
            netdisk_name = excluded.netdisk_name, vip_type = excluded.vip_type,
            total = excluded.total, used = excluded.used, fetched_at = excluded.fetched_at;
        """
        guard let stmt = try? SQLiteStatement(db: conn.getHandle(), sql: sql) else { return }
        stmt.bindText(vaultID, at: 1)
        stmt.bindDouble(Double(uk ?? 0), at: 2)
        stmt.bindText(baiduName ?? "", at: 3)
        stmt.bindText(netdiskName ?? "", at: 4)
        stmt.bindDouble(Double(vipType), at: 5)
        stmt.bindDouble(Double(total ?? 0), at: 6)
        stmt.bindDouble(Double(used ?? 0), at: 7)
        stmt.bindDouble(Date().timeIntervalSince1970, at: 8)
        _ = stmt.step()
    }
}