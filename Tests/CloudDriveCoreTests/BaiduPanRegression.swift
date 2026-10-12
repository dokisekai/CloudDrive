//
//  BaiduPanRegression.swift
//  CloudDriveCoreTests
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  百度网盘存储模块单元测试与集成回归测试套件
//

import Foundation
import CryptoKit
import CloudDriveCore
import CloudDriveContracts
import CloudDriveStorage
import CloudDrivePersistence

private struct BaiduPanTestFailure: Error, CustomStringConvertible {
    let description: String
}

// MARK: - Mock URL Protocol for Baidu Pan

final class MockBaiduPanURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    
    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }
    
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }
    
    override func startLoading() {
        guard let handler = MockBaiduPanURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: BaiduPanTestFailure(description: "No handler registered"))
            return
        }
        
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    
    override func stopLoading() {}
}

extension URLRequest {
    var fullBodyData: Data? {
        if let body = self.httpBody {
            return body
        }
        guard let stream = self.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return data
    }
}

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockBaiduPanURLProtocol.self]
    return URLSession(configuration: config)
}

// MARK: - Baidu Pan Regression Suite

public func runBaiduPanRegressions() async throws {
    print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("☁️ Running Baidu Pan Storage Regressions")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

    func assert(_ condition: Bool, _ name: String) {
        if condition {
            print("  ✅ [BaiduPan] PASSED: \(name)")
        } else {
            print("  ❌ [BaiduPan] FAILED: \(name)")
            fatalError("Regression failed: \(name)")
        }
    }

    // 1. BaiduPanTier 测试
    do {
        print("  ▶ 1. Verifying BaiduPanTier characteristics...")
        let standard = BaiduPanTier.standard
        let vip = BaiduPanTier.vip
        let svip = BaiduPanTier.svip

        assert(standard.sliceSize == 4 * 1024 * 1024, "Standard slice size is 4MB")
        assert(standard.maxFileSize == 4 * 1024 * 1024 * 1024, "Standard max file size is 4GB")

        assert(vip.sliceSize == 16 * 1024 * 1024, "VIP slice size is 16MB")
        assert(vip.maxFileSize == 10 * 1024 * 1024 * 1024, "VIP max file size is 10GB")

        assert(svip.sliceSize == 32 * 1024 * 1024, "SVIP slice size is 32MB")
        assert(svip.maxFileSize == 20 * 1024 * 1024 * 1024, "SVIP max file size is 20GB")

        assert(BaiduPanTier(vipType: 0) == .standard, "vipType 0 maps to standard")
        assert(BaiduPanTier(vipType: 1) == .vip, "vipType 1 maps to vip")
        assert(BaiduPanTier(vipType: 2) == .svip, "vipType 2 maps to svip")
        assert(BaiduPanTier(vipType: 99) == .standard, "Unknown vipType maps to standard")
    }

    // 2. BaiduPanPathFence 测试
    do {
        print("  ▶ 2. Verifying BaiduPanPathFence prefix & resolution...")
        let fence = BaiduPanPathFence(appFolderName: "CloudDrive")
        assert(fence.prefix == "/apps/CloudDrive", "Fence prefix is /apps/CloudDrive")

        let customFence = BaiduPanPathFence(appFolderName: "/MyCustomFolder///")
        assert(customFence.prefix == "/apps/MyCustomFolder", "Fence sanitizes trailing and leading slashes")

        assert(try fence.resolve("/") == "/apps/CloudDrive", "Root path resolves to fence prefix")
        assert(try fence.resolve("") == "/apps/CloudDrive", "Empty path resolves to fence prefix")
        assert(try fence.resolve("/vault/file.txt") == "/apps/CloudDrive/vault/file.txt", "Relative subpath resolves correctly")
        assert(try fence.resolve("///abc/def//") == "/apps/CloudDrive/abc/def", "Multiple slashes sanitized")
        assert(try fence.resolve("/apps/CloudDrive/vault/file.txt") == "/apps/CloudDrive/vault/file.txt", "Idempotent resolve prevents duplicate prefix")
        assert(try fence.resolve("apps/CloudDrive/vault/file.txt") == "/apps/CloudDrive/vault/file.txt", "Unslashed physical path resolves safely without duplicate")

        assert(fence.toLogicalPath("/apps/CloudDrive") == "/", "Prefix to logical path is /")
        assert(fence.toLogicalPath("/apps/CloudDrive/vault/key.bin") == "/vault/key.bin", "Remote path to logical path")
        assert(fence.toLogicalPath("/apps/CloudDrive/apps/CloudDrive/doc.txt") == "/doc.txt", "Multi-prefix sanitized cleanly to logical path")

        var deniedCaught = false
        do {
            try fence.assertWithinFence("/other_dir/file.txt")
        } catch StorageError.permissionDenied {
            deniedCaught = true
        } catch {}
        assert(deniedCaught, "Path outside fence throws permissionDenied")

        assert(BaiduPanPathFence.isValidFileName("normal_name.txt"), "Valid file name accepted")
        assert(!BaiduPanPathFence.isValidFileName(""), "Empty name rejected")
        assert(!BaiduPanPathFence.isValidFileName("."), "Dot rejected")
        assert(!BaiduPanPathFence.isValidFileName(".."), "Dot-dot rejected")
        assert(!BaiduPanPathFence.isValidFileName("invalid/name"), "Slash in name rejected")
        assert(!BaiduPanPathFence.isValidFileName("bad:char"), "Colon in name rejected")
    }

    // 3. BaiduPanErrorMapping 测试
    do {
        print("  ▶ 3. Verifying BaiduPanErrorMapping...")
        assert(BaiduPanErrorMapping.shouldRefreshToken(errno: -6), "errno -6 triggers token refresh")
        assert(BaiduPanErrorMapping.shouldRefreshToken(errno: 20016), "errno 20016 triggers token refresh")
        assert(BaiduPanErrorMapping.shouldRefreshToken(errno: 20017), "errno 20017 triggers token refresh")
        assert(BaiduPanErrorMapping.shouldRefreshToken(errno: 31045), "errno 31045 triggers token refresh")
        assert(!BaiduPanErrorMapping.shouldRefreshToken(errno: -9), "errno -9 does not trigger token refresh")
        assert(!BaiduPanErrorMapping.shouldRefreshToken(errno: 31061), "errno 31061 does not trigger token refresh")

        if case .notFound = BaiduPanErrorMapping.map(errno: -9, errmsg: nil) {
            assert(true, "-9 maps to notFound")
        } else {
            assert(false, "-9 maps to notFound")
        }

        if case .notFound = BaiduPanErrorMapping.map(errno: 31066, errmsg: nil) {
            assert(true, "31066 maps to notFound")
        } else {
            assert(false, "31066 maps to notFound")
        }

        if case .fileSystemError = BaiduPanErrorMapping.map(errno: 31061, errmsg: nil) {
            assert(true, "31061 maps to fileSystemError (already exists)")
        } else {
            assert(false, "31061 maps to fileSystemError")
        }

        if case .authenticationFailed = BaiduPanErrorMapping.map(errno: -6, errmsg: nil) {
            assert(true, "-6 maps to authenticationFailed")
        } else {
            assert(false, "-6 maps to authenticationFailed")
        }

        if case .serverError(let code, _) = BaiduPanErrorMapping.map(errno: 31034, errmsg: "rate limit"), code == 429 {
            assert(true, "31034 maps to 429 rate limit")
        } else {
            assert(false, "31034 maps to 429 rate limit")
        }

        if case .serverError(let code, _) = BaiduPanErrorMapping.map(errno: 31360, errmsg: "dlink expired"), code == 410 {
            assert(true, "31360 maps to 410 dlink expired")
        } else {
            assert(false, "31360 maps to 410 dlink expired")
        }
    }

    // 4. BaiduPanTokenStore 单元与并发持久化测试
    do {
        print("  ▶ 4. Verifying BaiduPanTokenStore in isolated SQLite database...")
        let tempDB = FileManager.default.temporaryDirectory.appendingPathComponent("bp_test_\(UUID().uuidString).db")
        defer {
            try? FileManager.default.removeItem(at: tempDB)
            try? FileManager.default.removeItem(at: tempDB.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: tempDB.appendingPathExtension("shm"))
        }

        let store = BaiduPanTokenStore(dbURL: tempDB)
        let vaultID = "test_vault_\(UUID().uuidString)"

        try store.saveAuthorized(
            vaultID: vaultID,
            appID: "123456",
            clientID: "mock_client_id",
            accessToken: "mock_access_token_1",
            refreshToken: "mock_refresh_token_1",
            expiresIn: 3600
        )

        assert(!store.needsReauth(vaultID: vaultID), "Newly authorized token does not need reauth")

        let token = try await store.validAccessToken(
            vaultID: vaultID,
            refresh: { _ in
                fatalError("Should not trigger refresher when token is fresh")
            }
        )
        assert(token == "mock_access_token_1", "Retrieved valid access token matches saved")

        // 测试 dlink 缓存与失效
        store.storeDlink(path: "/apps/CloudDrive/test.txt", dlink: "https://d.pcs.baidu.com/file/mock", fsID: 998877)
        let cached = store.cachedDlink(path: "/apps/CloudDrive/test.txt")
        assert(cached?.dlink == "https://d.pcs.baidu.com/file/mock", "dlink stored and retrieved")
        assert(cached?.fsID == 998877, "fsID stored and retrieved")

        store.invalidateDlink(path: "/apps/CloudDrive/test.txt")
        assert(store.cachedDlink(path: "/apps/CloudDrive/test.txt") == nil, "dlink invalidated successfully")

        // 测试 Upload Checkpoint 存取
        let cp = BaiduPanUploadCheckpoint(
            path: "/apps/CloudDrive/large.bin",
            uploadid: "upload_id_12345",
            size: 8 * 1024 * 1024,
            sliceSize: 4 * 1024 * 1024,
            rtype: 3,
            blockMD5: ["md5_1", "md5_2"],
            completedSlices: [0],
            sliceMD5s: ["md5_1", "md5_2"],
            state: .uploading
        )
        store.saveCheckpoint(cp)
        let loadedCp = store.loadCheckpoint(path: "/apps/CloudDrive/large.bin")
        assert(loadedCp?.uploadid == "upload_id_12345", "Checkpoint uploadid preserved")
        assert(loadedCp?.completedSlices == [0], "Checkpoint completed slices preserved")

        store.clearCheckpoint(path: "/apps/CloudDrive/large.bin")
        assert(store.loadCheckpoint(path: "/apps/CloudDrive/large.bin") == nil, "Checkpoint cleared")

        // 测试 用户信息与 VIP Tier 缓存
        store.storeUserInfo(
            vaultID: vaultID,
            uk: 10001,
            baiduName: "CloudDriveTester",
            netdiskName: "TesterNetdisk",
            vipType: 2,
            total: 2_000_000_000,
            used: 500_000_000
        )
        let cachedTier = store.cachedTier(vaultID: vaultID)
        assert(cachedTier == .svip, "Cached tier is SVIP")

        // 验证 bootstrap 对 Access Token (127.x) 的智能识别 (免刷新即可使用)
        let directAccessVault = "vault_direct_access"
        let mock127Token = "127.6ed3c17573b7d942c58abff9809e2d8a.YGhid9JsMockAccessToken.ABC123"
        try store.bootstrap(vaultID: directAccessVault, appID: "app_1", clientID: "k", refreshToken: mock127Token)
        let resolvedDirect = try await store.validAccessToken(vaultID: directAccessVault) { _ in
            fatalError("Should not trigger OAuth refresh for 127.x Access Token")
        }
        assert(resolvedDirect == mock127Token, "127.x Access Token directly recognized and ready to use")

        // 验证 bootstrap 对 Refresh Token (126.x) 的处理 (触发 OAuth 刷新)
        let directRefreshVault = "vault_direct_refresh"
        let mock126Token = "126.6ed3c17573b7d942c58abff9809e2d8a.MockRefreshToken"
        try store.bootstrap(vaultID: directRefreshVault, appID: "app_1", clientID: "k", refreshToken: mock126Token)
        var refresherInvoked = false
        let resolvedRefresh = try await store.validAccessToken(vaultID: directRefreshVault) { ref in
            assert(ref == mock126Token, "Refresher called with 126.x token")
            refresherInvoked = true
            return ("new_access_token", "new_refresh_token", 3600)
        }
        assert(refresherInvoked, "OAuth refresh invoked for 126.x Refresh Token")
        assert(resolvedRefresh == "new_access_token", "Exchanged access token saved")

        // 验证凭据克隆 (default -> 新 vault) 与避免误杀
        let clonedVault = "vault_cloned_uuid"
        store.cloneCredentials(from: directRefreshVault, to: clonedVault)
        let resolvedCloned = try await store.validAccessToken(vaultID: clonedVault) { _ in
            fatalError("Should not trigger OAuth refresh for cloned valid credentials")
        }
        assert(resolvedCloned == "new_access_token", "Cloned credentials directly valid without re-refresh")

        // 验证 forceInvalidateToken 能够清除有效期促使刷新
        store.forceInvalidateToken(vaultID: clonedVault)
        var forceRefreshed = false
        _ = try await store.validAccessToken(vaultID: clonedVault) { _ in
            forceRefreshed = true
            return ("forced_new_access", "forced_new_refresh", 3600)
        }
        assert(forceRefreshed, "forceInvalidateToken triggered refresh successfully")
    }

    // 5. Mock HTTP 集成测试：User-Agent 检查与基础接口
    do {
        print("  ▶ 5. Verifying Mock HTTP request headers & API gateway...")
        let mockSession = makeMockSession()
        let tempDB = FileManager.default.temporaryDirectory.appendingPathComponent("bp_http_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tempDB) }
        let store = BaiduPanTokenStore(dbURL: tempDB)
        let vaultID = "http_vault_1"
        try store.saveAuthorized(
            vaultID: vaultID,
            appID: "app_1",
            clientID: "key_1",
            accessToken: "test_token_abc",
            refreshToken: "test_refresh_abc",
            expiresIn: 3600
        )

        var userAgentVerified = false

        MockBaiduPanURLProtocol.requestHandler = { request in
            if let ua = request.value(forHTTPHeaderField: "User-Agent"), ua == "pan.baidu.com" {
                userAgentVerified = true
            }

            guard let url = request.url?.absoluteString else {
                throw BaiduPanTestFailure(description: "No URL")
            }

            if url.contains("uinfo") {
                let json = """
                {
                    "errno": 0,
                    "baidu_name": "AntigravityUser",
                    "netdisk_name": "DriveUser",
                    "vip_type": 2,
                    "uk": 123456789
                }
                """.data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
            }

            if url.contains("quota") {
                let json = """
                {
                    "errno": 0,
                    "total": 1073741824000,
                    "used": 107374182400,
                    "free": 966367641600
                }
                """.data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
            }

            if url.contains("method=list") {
                let json = """
                {
                    "errno": 0,
                    "list": []
                }
                """.data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
            }

            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let config = BaiduPanStorageConfig(
            appID: "app_1",
            appKey: "key_1",
            clientSecret: "secret_1",
            appFolderName: "CloudDrive"
        )
        let client = BaiduPanStorageClient(
            config: config,
            vaultID: vaultID,
            session: mockSession,
            tokenStore: store
        )

        let connected = try await client.testConnection()
        assert(connected, "testConnection succeeds via Mock HTTP")
        assert(userAgentVerified, "User-Agent: pan.baidu.com header strictly verified on all requests")
    }

    // 6. Mock HTTP: 目录列举与 synthesizedETag
    do {
        print("  ▶ 6. Verifying listDirectory and synthesizedETag...")
        let mockSession = makeMockSession()
        let tempDB = FileManager.default.temporaryDirectory.appendingPathComponent("bp_list_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tempDB) }
        let store = BaiduPanTokenStore(dbURL: tempDB)
        let vaultID = "list_vault"
        try store.saveAuthorized(vaultID: vaultID, appID: "app_1", clientID: "k", accessToken: "tok", refreshToken: "ref", expiresIn: 3600)

        MockBaiduPanURLProtocol.requestHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("method=list") {
                let json = """
                {
                    "errno": 0,
                    "list": [
                        {
                            "fs_id": 10001,
                            "path": "/apps/CloudDrive/vault.cryptomator",
                            "server_filename": "vault.cryptomator",
                            "size": 128,
                            "isdir": 0,
                            "server_mtime": 1700000000
                        },
                        {
                            "fs_id": 20002,
                            "path": "/apps/CloudDrive/d",
                            "server_filename": "d",
                            "size": 0,
                            "isdir": 1,
                            "server_mtime": 1700000001
                        }
                    ]
                }
                """.data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let config = BaiduPanStorageConfig(appFolderName: "CloudDrive")
        let client = BaiduPanStorageClient(config: config, vaultID: vaultID, session: mockSession, tokenStore: store)

        let items = try await client.listDirectory(path: "/")
        assert(items.count == 2, "Listed 2 items in root directory")
        let file = items.first { !$0.isDirectory }!
        let dir = items.first { $0.isDirectory }!

        assert(file.path == "/vault.cryptomator", "File logical path mapped correctly")
        assert(file.contentLength == 128, "File size is 128")
        assert(file.etag == "bp-10001-128-1700000000", "Synthesized ETag format verified for file")

        assert(dir.path == "/d", "Directory logical path mapped correctly")
        assert(dir.etag == "bp-dir-20002", "Synthesized ETag format verified for directory")
    }

    // 6.1 Mock HTTP: exists(path:) 文件与目录双模探测验证 (修复 Cryptomator 'd' 目录校验)
    do {
        print("  ▶ 6.1 Verifying exists(path:) for files and directories (Cryptomator 'd' directory check)...")
        let mockSession = makeMockSession()
        let tempDB = FileManager.default.temporaryDirectory.appendingPathComponent("bp_exists_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tempDB) }
        let store = BaiduPanTokenStore(dbURL: tempDB)
        let vaultID = "exists_vault"
        try store.saveAuthorized(vaultID: vaultID, appID: "app_1", clientID: "k", accessToken: "tok", refreshToken: "ref", expiresIn: 3600)

        MockBaiduPanURLProtocol.requestHandler = { request in
            let url = request.url?.absoluteString ?? ""
            // 文件 meta 探测：仅 /apps/CloudDrive/vault.cryptomator 命中
            if url.contains("method=meta") {
                if url.contains("path=%2Fapps%2FCloudDrive%2Fvault.cryptomator") || url.contains("path=/apps/CloudDrive/vault.cryptomator") {
                    let json = """
                    {"errno": 0, "list": [{"fs_id": 10001, "path": "/apps/CloudDrive/vault.cryptomator", "server_filename": "vault.cryptomator", "isdir": 0}]}
                    """.data(using: .utf8)!
                    return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
                } else {
                    // 目录或不存在的文件：百度 meta 接口返回 errno: -9
                    let json = """
                    {"errno": -9, "errmsg": "file not found"}
                    """.data(using: .utf8)!
                    return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
                }
            }

            // 目录 list 探测：/apps/CloudDrive/d 存在 (空目录)
            if url.contains("method=list") {
                if url.contains("dir=%2Fapps%2FCloudDrive%2Fd") || url.contains("dir=/apps/CloudDrive/d") {
                    let json = """
                    {"errno": 0, "guid_info": "", "list": []}
                    """.data(using: .utf8)!
                    return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
                } else {
                    let json = """
                    {"errno": -9, "errmsg": "file not found"}
                    """.data(using: .utf8)!
                    return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
                }
            }

            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let config = BaiduPanStorageConfig(appFolderName: "CloudDrive")
        let client = BaiduPanStorageClient(config: config, vaultID: vaultID, session: mockSession, tokenStore: store)

        // 1. 根目录应当返回 true
        let rootExists = try await client.exists(path: "/")
        assert(rootExists, "Root directory exists returns true")

        // 2. 文件应当通过 meta 返回 true
        let fileExists = try await client.exists(path: "/vault.cryptomator")
        assert(fileExists, "File exists returns true via meta")

        // 3. 目录应当在 meta 返回 -9 后通过 list 探测返回 true (关键修复！)
        let dirExists = try await client.exists(path: "/d")
        assert(dirExists, "Cryptomator 'd' directory exists returns true via directory list probe")

        // 4. 不存在的路径应当返回 false
        let nonExistent = try await client.exists(path: "/non_existent")
        assert(!nonExistent, "Non-existent path returns false")
    }

    // 7. Mock HTTP: Range 下载与 HTTP Range 请求头校验
    do {
        print("  ▶ 7. Verifying Range download with HTTP Range header...")
        let mockSession = makeMockSession()
        let tempDB = FileManager.default.temporaryDirectory.appendingPathComponent("bp_range_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tempDB) }
        let store = BaiduPanTokenStore(dbURL: tempDB)
        let vaultID = "range_vault"
        try store.saveAuthorized(vaultID: vaultID, appID: "app_1", clientID: "k", accessToken: "tok", refreshToken: "ref", expiresIn: 3600)

        var requestedRangeHeader: String?

        MockBaiduPanURLProtocol.requestHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("method=meta") {
                let json = """
                {
                    "errno": 0,
                    "list": [
                        {
                            "fs_id": 5566,
                            "path": "/apps/CloudDrive/cipher.c9r",
                            "server_filename": "cipher.c9r",
                            "size": 1000,
                            "isdir": 0,
                            "dlink": "https://d.pcs.baidu.com/file/download_raw"
                        }
                    ]
                }
                """.data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
            }

            if url.contains("download_raw") {
                requestedRangeHeader = request.value(forHTTPHeaderField: "Range")
                let chunk = Data(repeating: 0x42, count: 100)
                return (HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: nil)!, chunk)
            }

            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let config = BaiduPanStorageConfig(appFolderName: "CloudDrive")
        let client = BaiduPanStorageClient(config: config, vaultID: vaultID, session: mockSession, tokenStore: store)

        let rangeData = try await client.downloadRange(path: "/cipher.c9r", range: 0...99)
        assert(rangeData.count == 100, "Downloaded 100 bytes via range read")
        assert(requestedRangeHeader == "bytes=0-99", "Range header formatted exactly as bytes=0-99 (no off-by-one)")
    }

    // 8. Mock HTTP: 端到端分片上传流程 (precreate -> locateupload -> superfile2 -> create)
    do {
        print("  ▶ 8. Verifying end-to-end chunked upload flow...")
        let mockSession = makeMockSession()
        let tempDB = FileManager.default.temporaryDirectory.appendingPathComponent("bp_upload_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tempDB) }
        let store = BaiduPanTokenStore(dbURL: tempDB)
        let vaultID = "upload_vault"
        try store.saveAuthorized(vaultID: vaultID, appID: "app_1", clientID: "k", accessToken: "tok", refreshToken: "ref", expiresIn: 3600)

        var precreateCalled = false
        var locateUploadCalled = false
        var superfile2Called = false
        var createCalled = false

        MockBaiduPanURLProtocol.requestHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("method=precreate") {
                precreateCalled = true
                let json = """
                {
                    "errno": 0,
                    "uploadid": "mock_up_id_999",
                    "return_type": 1,
                    "block_list": [0]
                }
                """.data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
            }

            if url.contains("locateupload") {
                locateUploadCalled = true
                let json = """
                {
                    "error_code": 0,
                    "host": "c.pcs.baidu.com",
                    "expire": 60
                }
                """.data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
            }

            if url.contains("superfile2") {
                superfile2Called = true
                let json = """
                {
                    "errno": 0,
                    "md5": "mock_slice_md5"
                }
                """.data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
            }

            if url.contains("method=create") {
                createCalled = true
                let json = """
                {
                    "errno": 0,
                    "fs_id": 88888,
                    "md5": "file_md5_full",
                    "path": "/apps/CloudDrive/upload.txt",
                    "size": 1024,
                    "ctime": 1700000000,
                    "mtime": 1700000000,
                    "isdir": 0
                }
                """.data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
            }

            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let tempUploadFile = FileManager.default.temporaryDirectory.appendingPathComponent("test_up_\(UUID().uuidString).bin")
        try Data(repeating: 0x55, count: 1024).write(to: tempUploadFile)
        defer { try? FileManager.default.removeItem(at: tempUploadFile) }

        let config = BaiduPanStorageConfig(appFolderName: "CloudDrive")
        let client = BaiduPanStorageClient(config: config, vaultID: vaultID, session: mockSession, tokenStore: store)

        let etag = try await client.uploadFile(localURL: tempUploadFile, to: "/upload.txt", mode: .forceOverwrite, progress: { _ in })
        assert(precreateCalled, "precreate step executed")
        assert(locateUploadCalled, "locateupload step executed")
        assert(superfile2Called, "superfile2 slice upload step executed")
        assert(createCalled, "create commit step executed")
        assert(etag != nil, "Synthesized ETag returned on upload completion")
    }

    // 9. StorageClientFactory 实例化验证
    do {
        print("  ▶ 9. Verifying StorageClientFactory instantiation...")
        let config = StorageConfiguration.baidupan(BaiduPanStorageConfig(
            appID: "app_fact",
            appKey: "key_fact",
            clientSecret: "sec_fact",
            appFolderName: "CloudDrive"
        ))
        assert(config.type.isAvailable, "StorageType.baidupan is available")
        let client = StorageClientFactory.createClient(configuration: config)
        assert(client is BaiduPanStorageClient, "Factory produced BaiduPanStorageClient instance")
        assert(client.capabilities.supportsResumableDownload, "Capabilities indicate resumable download supported")
        assert(client.capabilities.supportsResumableUpload, "Capabilities indicate resumable upload supported")
        assert(client.capabilities.supportsServerSideMove, "Capabilities indicate server-side move supported")
        assert(client.capabilities.supportsServerSideCopy, "Capabilities indicate server-side copy supported")
    }

    // 10. 访达所有文件系统操作端到端验证 (创建目录、写入文件、读取、Range读取、重命名、移动、复制、删除、列举)
    do {
        print("  ▶ 10. Verifying Finder full-lifecycle operations on BaiduPan storage...")
        let mockSession = makeMockSession()
        let tempDB = FileManager.default.temporaryDirectory.appendingPathComponent("bp_finder_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tempDB) }
        let store = BaiduPanTokenStore(dbURL: tempDB)
        let vaultID = "finder_vault_test"
        try store.saveAuthorized(vaultID: vaultID, appID: "app_f", clientID: "k_f", accessToken: "tok_f", refreshToken: "ref_f", expiresIn: 3600)

        // 维护 Mock 内存文件树
        class MockBaiduPanVFS: @unchecked Sendable {
            var files: [String: (isdir: Bool, size: Int64, data: Data)] = [
                "/apps/CloudDrive": (isdir: true, size: 0, data: Data())
            ]
            let lock = NSLock()
        }
        let vfs = MockBaiduPanVFS()

        MockBaiduPanURLProtocol.requestHandler = { request in
            guard let url = request.url?.absoluteString else {
                throw BaiduPanTestFailure(description: "No URL")
            }
            vfs.lock.lock()
            defer { vfs.lock.unlock() }

            // 1. 列举接口
            if url.contains("method=list") {
                let components = URLComponents(string: url)!
                let dir = components.queryItems?.first(where: { $0.name == "dir" })?.value ?? "/apps/CloudDrive"
                guard let dirMeta = vfs.files[dir], dirMeta.isdir else {
                    let json = "{\"errno\": -9, \"errmsg\": \"file not found\"}".data(using: .utf8)!
                    return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
                }
                var listItems: [String] = []
                for (path, meta) in vfs.files where path != dir {
                    let parent = (path as NSString).deletingLastPathComponent
                    if parent == dir {
                        let name = (path as NSString).lastPathComponent
                        listItems.append("""
                        {
                            "fs_id": \(abs(path.hashValue) % 100000 + 1000),
                            "path": "\(path)",
                            "server_filename": "\(name)",
                            "size": \(meta.size),
                            "isdir": \(meta.isdir ? 1 : 0),
                            "server_mtime": 1700000000
                        }
                        """)
                    }
                }
                let json = "{\"errno\": 0, \"list\": [\(listItems.joined(separator: ","))]}".data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
            }

            // 2. 元数据接口 (支持 legacy meta 与 official filemetas)
            if url.contains("method=meta") || url.contains("method=filemetas") {
                let components = URLComponents(string: url)!
                let path = components.queryItems?.first(where: { $0.name == "path" })?.value ?? ""
                let fsidsStr = components.queryItems?.first(where: { $0.name == "fsids" })?.value ?? ""
                var targetFile: (path: String, meta: (isdir: Bool, size: Int64, data: Data))? = nil
                if !path.isEmpty, let m = vfs.files[path] {
                    targetFile = (path, m)
                } else if !fsidsStr.isEmpty {
                    for (p, m) in vfs.files {
                        let id = abs(p.hashValue) % 100000 + 1000
                        if fsidsStr.contains(String(id)) {
                            targetFile = (p, m)
                            break
                        }
                    }
                }
                if let target = targetFile {
                    let name = (target.path as NSString).lastPathComponent
                    let json = """
                    {
                        "errno": 0,
                        "list": [{
                            "fs_id": \(abs(target.path.hashValue) % 100000 + 1000),
                            "path": "\(target.path)",
                            "server_filename": "\(name)",
                            "size": \(target.meta.size),
                            "isdir": \(target.meta.isdir ? 1 : 0),
                            "server_mtime": 1700000000,
                            "dlink": "https://d.pcs.baidu.com/mockdownload?file=\(name)"
                        }]
                    }
                    """.data(using: .utf8)!
                    return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
                } else {
                    let json = "{\"errno\": -9, \"errmsg\": \"file not found\"}".data(using: .utf8)!
                    return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
                }
            }

            // 3. 创建目录
            if url.contains("method=create") {
                let bodyStr = String(data: request.fullBodyData ?? Data(), encoding: .utf8) ?? ""
                let isDir = bodyStr.contains("isdir=1")
                if isDir {
                    // 创建目录
                    let pairs = bodyStr.components(separatedBy: "&")
                    var dirPath = ""
                    for p in pairs {
                        let kv = p.components(separatedBy: "=")
                        if kv.count == 2 && kv[0] == "path" {
                            dirPath = kv[1].removingPercentEncoding ?? kv[1]
                        }
                    }
                    if dirPath.isEmpty {
                        let comp = URLComponents(string: url)
                        dirPath = comp?.queryItems?.first(where: { $0.name == "path" })?.value ?? ""
                    }
                    vfs.files[dirPath] = (isdir: true, size: 0, data: Data())
                    let json = "{\"errno\": 0, \"fs_id\": \(abs(dirPath.hashValue) % 100000 + 1000), \"path\": \"\(dirPath)\", \"isdir\": 1, \"mtime\": 1700000000}".data(using: .utf8)!
                    return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
                } else {
                    // 分片合并完成文件
                    let pairs = bodyStr.components(separatedBy: "&")
                    var filePath = ""
                    var size: Int64 = 0
                    for p in pairs {
                        let kv = p.components(separatedBy: "=")
                        if kv.count == 2 && kv[0] == "path" {
                            filePath = kv[1].removingPercentEncoding ?? kv[1]
                        } else if kv.count == 2 && kv[0] == "size" {
                            size = Int64(kv[1]) ?? 0
                        }
                    }
                    // 保留之前分片写入的数据
                    let oldData = vfs.files[filePath]?.data ?? Data()
                    vfs.files[filePath] = (isdir: false, size: size, data: oldData)
                    let json = "{\"errno\": 0, \"fs_id\": \(abs(filePath.hashValue) % 100000 + 1000), \"path\": \"\(filePath)\", \"isdir\": 0, \"size\": \(size), \"mtime\": 1700000000}".data(using: .utf8)!
                    return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
                }
            }

            // 4. 上传分片准备 precreate
            if url.contains("method=precreate") {
                let bodyStr = String(data: request.fullBodyData ?? Data(), encoding: .utf8) ?? ""
                let pairs = bodyStr.components(separatedBy: "&")
                var path = ""
                for p in pairs {
                    let kv = p.components(separatedBy: "=")
                    if kv.count == 2 && kv[0] == "path" {
                        path = kv[1].removingPercentEncoding ?? kv[1]
                    }
                }
                let json = "{\"errno\": 0, \"uploadid\": \"upload_\(abs(path.hashValue))\", \"block_list\": [0]}".data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
            }

            // 5. 动态节点 locateupload
            if url.contains("method=locateupload") {
                let json = "{\"error_code\": 0, \"host\": \"c.pcs.baidu.com\", \"expire\": 60}".data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
            }

            // 6. 分片上传 superfile2
            if url.contains("superfile2") {
                let components = URLComponents(string: url)!
                let path = components.queryItems?.first(where: { $0.name == "path" })?.value ?? ""
                var fileBytes = request.fullBodyData ?? Data()
                if fileBytes.isEmpty {
                    fileBytes = Data("Hello BaiduPan Finder Lifecycle!".utf8)
                }
                vfs.files[path] = (isdir: false, size: Int64(fileBytes.count), data: fileBytes)
                let json = "{\"errno\": 0, \"md5\": \"mock_md5\"}".data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
            }

            // 7. dlink 文件下载与 Range 范围读取
            if url.contains("mockdownload") {
                let components = URLComponents(string: url)!
                let file = components.queryItems?.first(where: { $0.name == "file" })?.value ?? ""
                var foundData = Data("Hello BaiduPan Finder Lifecycle!".utf8)
                for (p, m) in vfs.files where p.hasSuffix(file) {
                    if !m.data.isEmpty {
                        foundData = m.data
                    }
                    break
                }

                if let rangeHeader = request.value(forHTTPHeaderField: "Range"), rangeHeader.hasPrefix("bytes=") {
                    let rangeStr = String(rangeHeader.dropFirst("bytes=".count))
                    let parts = rangeStr.components(separatedBy: "-")
                    if parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]), start <= end && end < foundData.count {
                        let sub = foundData.subdata(in: start..<(end + 1))
                        return (HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: ["Content-Range": "bytes \(start)-\(end)/\(foundData.count)"])!, sub)
                    }
                }
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, foundData)
            }

            // 8. filemanager (move, copy, delete)
            if url.contains("method=filemanager") {
                let components = URLComponents(string: url)!
                let opera = components.queryItems?.first(where: { $0.name == "opera" })?.value ?? ""
                let bodyStr = String(data: request.fullBodyData ?? Data(), encoding: .utf8) ?? ""
                let pairs = bodyStr.components(separatedBy: "&")
                var filelistJson = ""
                for p in pairs {
                    let kv = p.components(separatedBy: "=")
                    if kv.count == 2 && kv[0] == "filelist" {
                        filelistJson = kv[1].removingPercentEncoding ?? kv[1]
                    }
                }

                if let listData = filelistJson.data(using: .utf8) {
                    if opera == "delete" {
                        if let strArray = try? JSONSerialization.jsonObject(with: listData) as? [String] {
                            for path in strArray {
                                vfs.files.removeValue(forKey: path)
                                let prefix = path.hasSuffix("/") ? path : path + "/"
                                for key in Array(vfs.files.keys) where key.hasPrefix(prefix) {
                                    vfs.files.removeValue(forKey: key)
                                }
                            }
                        }
                    } else if let array = try? JSONSerialization.jsonObject(with: listData) as? [[String: String]] {
                        for item in array {
                            let path = item["path"] ?? ""
                            if opera == "move" {
                                let dest = item["dest"] ?? ""
                                let newname = item["newname"] ?? (path as NSString).lastPathComponent
                                let target = "\(dest)/\(newname)"
                                if let old = vfs.files.removeValue(forKey: path) {
                                    vfs.files[target] = old
                                }
                            } else if opera == "copy" {
                                let dest = item["dest"] ?? ""
                                let newname = item["newname"] ?? (path as NSString).lastPathComponent
                                let target = "\(dest)/\(newname)"
                                if let old = vfs.files[path] {
                                    vfs.files[target] = old
                                }
                            }
                        }
                    }
                }
                let json = "{\"errno\": 0, \"info\": [{\"errno\": 0}]}".data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
            }

            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let config = BaiduPanStorageConfig(appFolderName: "CloudDrive")
        let client = BaiduPanStorageClient(config: config, vaultID: vaultID, session: mockSession, tokenStore: store)

        // 操作 1：访达新建文件夹 (Create Directory)
        try await client.createDirectory(path: "/Documents")
        let docsExist = try await client.exists(path: "/Documents")
        assert(docsExist, "Finder Operation: Directory creation succeeded")

        // 操作 2：访达写入文件 (Create / Upload File)
        let localFile = FileManager.default.temporaryDirectory.appendingPathComponent("finder_hello_\(UUID().uuidString).txt")
        let fileContent = "Hello BaiduPan Finder Lifecycle!"
        try Data(fileContent.utf8).write(to: localFile)
        defer { try? FileManager.default.removeItem(at: localFile) }

        let etag = try await client.uploadFile(localURL: localFile, to: "/Documents/hello.txt", mode: .createIfAbsent, progress: { _ in })
        assert(etag != nil, "Finder Operation: File upload and ETag generation succeeded")
        let fileExists = try await client.exists(path: "/Documents/hello.txt")
        assert(fileExists, "Finder Operation: File existence probe confirmed")

        // 操作 3：访达双击打开 / 读取文件 (Fetch Contents / Download)
        let downloadTarget = FileManager.default.temporaryDirectory.appendingPathComponent("finder_downloaded_\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: downloadTarget) }
        try await client.downloadFile(path: "/Documents/hello.txt", to: downloadTarget, progress: { _ in })
        let readData = try Data(contentsOf: downloadTarget)
        assert(readData.count > 0, "Finder Operation: File downloaded successfully")

        // 操作 4：访达分块/范围读取 (Range Read for QuickLook / Cryptomator header)
        let rangeData = try await client.downloadRange(path: "/Documents/hello.txt", range: 0...4)
        assert(rangeData.count == 5, "Finder Operation: downloadRange byte slice count matches 5 bytes")

        // 操作 5：访达文件重命名 (Rename within same directory)
        try await client.move(from: "/Documents/hello.txt", to: "/Documents/renamed.txt")
        let oldExists = try await client.exists(path: "/Documents/hello.txt")
        let renamedExists = try await client.exists(path: "/Documents/renamed.txt")
        assert(!oldExists, "Finder Operation: Old name is removed after rename")
        assert(renamedExists, "Finder Operation: Renamed file is present")

        // 操作 6：访达移动文件到新目录 (Move / Reparent to Root)
        try await client.move(from: "/Documents/renamed.txt", to: "/moved_to_root.txt")
        let inSubDir = try await client.exists(path: "/Documents/renamed.txt")
        let inRoot = try await client.exists(path: "/moved_to_root.txt")
        assert(!inSubDir, "Finder Operation: File removed from source directory after move")
        assert(inRoot, "Finder Operation: File arrived at target root directory")

        // 操作 7：访达复制文件 (Duplicate / Copy)
        try await client.copy(from: "/moved_to_root.txt", to: "/copied_backup.txt")
        let originalStillThere = try await client.exists(path: "/moved_to_root.txt")
        let copyIsThere = try await client.exists(path: "/copied_backup.txt")
        assert(originalStillThere, "Finder Operation: Original file preserved during copy")
        assert(copyIsThere, "Finder Operation: Copied duplicate created successfully")

        // 操作 8：访达目录列举 (Enumerate Directory)
        let rootResources = try await client.listDirectory(path: "/")
        assert(rootResources.contains(where: { $0.displayName == "Documents" && $0.isDirectory }), "Finder Operation: Directory enumerated in root")
        assert(rootResources.contains(where: { $0.displayName == "moved_to_root.txt" && !$0.isDirectory }), "Finder Operation: moved file enumerated")
        assert(rootResources.contains(where: { $0.displayName == "copied_backup.txt" && !$0.isDirectory }), "Finder Operation: copied file enumerated")

        // 操作 9：访达删除文件与文件夹 (Delete / Trash)
        try await client.delete(path: "/copied_backup.txt")
        try await client.delete(path: "/moved_to_root.txt")
        try await client.delete(path: "/Documents")
        let copyDeleted = try await client.exists(path: "/copied_backup.txt")
        let movedDeleted = try await client.exists(path: "/moved_to_root.txt")
        let docsDeleted = try await client.exists(path: "/Documents")
        assert(!copyDeleted, "Finder Operation: Copied file deleted successfully")
        assert(!movedDeleted, "Finder Operation: Moved file deleted successfully")
        assert(!docsDeleted, "Finder Operation: Directory deleted successfully")
    }

    // 11. 验证 dlink 失效主动重试与换链刷新 (解决访达文件不存在核心痛点)
    do {
        print("  ▶ 11. Verifying dlink renewal on expiration (HTTP 410 / errno 31360)...")
        let mockSession = makeMockSession()
        let tempDB = FileManager.default.temporaryDirectory.appendingPathComponent("bp_dlink_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tempDB) }
        let store = BaiduPanTokenStore(dbURL: tempDB)
        let vaultID = "dlink_renewal_vault"
        try store.saveAuthorized(vaultID: vaultID, appID: "app_1", clientID: "k", accessToken: "tok", refreshToken: "ref", expiresIn: 3600)

        // 预存一条旧的 dlink
        store.storeDlink(path: "/apps/CloudDrive/sample.txt", dlink: "https://d.pcs.baidu.com/file/old_expired_dlink", fsID: 8888)

        var metaCallCount = 0
        var oldDlinkAttemptCount = 0
        var freshDlinkAttemptCount = 0

        MockBaiduPanURLProtocol.requestHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("old_expired_dlink") {
                oldDlinkAttemptCount += 1
                // 模拟旧链接返回 410 Gone
                return (HTTPURLResponse(url: request.url!, statusCode: 410, httpVersion: nil, headerFields: nil)!, Data())
            }

            if url.contains("method=meta") && url.contains("dlink=1") {
                metaCallCount += 1
                let json = """
                {
                    "errno": 0,
                    "list": [
                        {
                            "fs_id": 8888,
                            "path": "/apps/CloudDrive/sample.txt",
                            "server_filename": "sample.txt",
                            "size": 26,
                            "isdir": 0,
                            "dlink": "https://d.pcs.baidu.com/file/fresh_renewed_dlink"
                        }
                    ]
                }
                """.data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
            }

            if url.contains("fresh_renewed_dlink") {
                freshDlinkAttemptCount += 1
                let content = Data("Fresh Renewed Baidu Content".utf8)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, content)
            }

            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let config = BaiduPanStorageConfig(appFolderName: "CloudDrive")
        let client = BaiduPanStorageClient(config: config, vaultID: vaultID, session: mockSession, tokenStore: store)

        let target = FileManager.default.temporaryDirectory.appendingPathComponent("dlink_success_\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: target) }

        try await client.downloadFile(path: "/sample.txt", to: target, progress: { _ in })
        let downloadedStr = try String(contentsOf: target, encoding: .utf8)

        assert(oldDlinkAttemptCount == 1, "Attempted cached dlink first")
        assert(metaCallCount == 1, "Invalidated old dlink and re-requested meta for fresh dlink")
        assert(freshDlinkAttemptCount == 1, "Downloaded successfully using fresh dlink")
        assert(downloadedStr == "Fresh Renewed Baidu Content", "Payload from renewed dlink verified")
    }

    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("🎉 ALL Baidu Pan Regressions Passed Successfully!")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
}
