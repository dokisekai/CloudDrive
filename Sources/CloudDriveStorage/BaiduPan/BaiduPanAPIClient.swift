//
//  BaiduPanAPIClient.swift
//  CloudDriveStorage
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  百度网盘开放平台 REST 网关
//  官方文档: https://pan.baidu.com/union/doc/
//
//  全局硬性要求：
//  1. 所有请求必须携带 `User-Agent: pan.baidu.com`（否则下载命中防盗链 31326）
//  2. 业务错误码 errno 装在 HTTP 200 响应体里，**不是** HTTP 状态码
//  3. 所有路径必须落在 `/apps/{appname}` 围栏内
//

import Foundation
import CloudDriveContracts
import CloudDriveSupport

public final class BaiduPanAPIClient: @unchecked Sendable {

    // MARK: - 常量

    public static let userAgent = "pan.baidu.com"
    static let apiBase = "https://pan.baidu.com/rest/2.0"
    static let multimediaBase = "https://pan.baidu.com/rest/2.0/xpan/multimedia"
    static let locateUploadBase = "https://d.pcs.baidu.com/rest/2.0/pcs/file"
    static let quotaBase = "https://pan.baidu.com/api/quota"
    static let oauthBase = "https://openapi.baidu.com/oauth/2.0"

    public let config: BaiduPanStorageConfig
    public let fence: BaiduPanPathFence
    let session: URLSession
    let limiter: BaiduPanRateLimiter
    let tokenStore: BaiduPanTokenStore
    let vaultID: String

    public init(
        config: BaiduPanStorageConfig,
        vaultID: String,
        session: URLSession = .shared,
        tokenStore: BaiduPanTokenStore = BaiduPanTokenStore(),
        baseRetryDelay: TimeInterval = 0.5,
        maxRetryCount: Int = 3
    ) {
        self.config = config
        self.fence = BaiduPanPathFence(appFolderName: config.appFolderName)
        self.session = session
        self.tokenStore = tokenStore
        self.vaultID = vaultID
        self.limiter = BaiduPanRateLimiter(
            maxRequestsPerMinute: config.maxRequestsPerMinute,
            maxRequestsPerDay: config.maxRequestsPerDay
        )
        if !config.accessToken.isEmpty {
            try? tokenStore.saveAuthorized(
                vaultID: vaultID,
                appID: config.appID,
                clientID: config.appKey,
                accessToken: config.accessToken,
                refreshToken: config.refreshToken,
                expiresIn: 25 * 86400
            )
        } else if !config.refreshToken.isEmpty {
            try? tokenStore.bootstrap(
                vaultID: vaultID,
                appID: config.appID,
                clientID: config.appKey,
                refreshToken: config.refreshToken
            )
        }
    }

    // MARK: - 请求基础设施

    func makeRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 60
        return req
    }

    /// 解包统一响应体并按 errno 分类。
    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let err as DecodingError {
            let body = String(data: data, encoding: .utf8) ?? "<binary \(data.count) bytes>"
            print("❌ [BaiduPan] JSON Decoding error for \(type): \(err)")
            print("   Response body was: \(body)")
            throw err
        }
    }

    /// 判定响应体是否为错误响应并映射为 StorageError。
    func throwIfFailed(_ body: BaiduPanResponse) throws {
        guard let errno = body.errno, errno != 0 else { return }
        Logger.shared.error(.system, "❌ [BaiduPan throwIfFailed] errno: \(errno), errmsg: \(body.errmsg ?? "nil"), show_msg: \(body.show_msg ?? "nil")")
        throw BaiduPanErrorMapping.map(errno: errno, errmsg: body.errmsg ?? body.show_msg)
    }

    /// 带令牌与限流的 GET。自动在 token 过期时刷新并重试一次。
    func authenticatedGET<T: Decodable>(
        url: URL,
        as type: T.Type,
        retryOnTokenExpiry: Bool = true
    ) async throws -> T {
        try await performGET(url: url, as: type, retryOnTokenExpiry: retryOnTokenExpiry)
    }

    func replaceTokenInURL(_ url: URL, with newToken: String) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "access_token" }
        items.append(URLQueryItem(name: "access_token", value: newToken))
        components.queryItems = items
        return components.url ?? url
    }

    func performGET<T: Decodable>(
        url: URL,
        as type: T.Type,
        retryOnTokenExpiry: Bool
    ) async throws -> T where T: Decodable {
        try limiter.consume()
        let token = try await accessToken()
        let req = makeRequest(url)
        _ = token // token 已在 query 中
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw StorageError.networkError("Invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw StorageError.serverError(statusCode: http.statusCode, message: "HTTP \(http.statusCode)")
        }
        let respStr = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
        Logger.shared.info(.system, "📡 [BaiduPan GET] URL: \(url.absoluteString), Status: \(http.statusCode), Body: \(respStr)")
        let body = (try? decode(BaiduPanResponse.self, from: data))
        if retryOnTokenExpiry, let errno = body?.errno, BaiduPanErrorMapping.shouldRefreshToken(errno: errno) {
            Logger.shared.warning(.system, "⚠️ [BaiduPan] Token expired (errno \(errno)), refreshing and retrying GET...")
            try await forceRefresh()
            let freshToken = try await accessToken()
            let updatedURL = replaceTokenInURL(url, with: freshToken)
            return try await performGET(url: updatedURL, as: type, retryOnTokenExpiry: false)
        }
        if let body { try throwIfFailed(body) }
        return try decode(type, from: data)
    }

    /// 表单 POST
    func formPOST<T: Decodable>(
        url: URL,
        body: [String: String],
        as type: T.Type,
        retryOnTokenExpiry: Bool = true
    ) async throws -> T {
        try await performFormPOST(url: url, body: body, as: type, retryOnTokenExpiry: retryOnTokenExpiry)
    }

    func performFormPOST<T: Decodable>(
        url: URL,
        body: [String: String],
        as type: T.Type,
        retryOnTokenExpiry: Bool
    ) async throws -> T where T: Decodable {
        try limiter.consume()
        var req = makeRequest(url)
        var components = URLComponents()
        components.queryItems = body.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw StorageError.networkError("Invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw StorageError.serverError(statusCode: http.statusCode, message: "HTTP \(http.statusCode)")
        }
        let respStr = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
        Logger.shared.info(.system, "📡 [BaiduPan POST] URL: \(url.absoluteString), Status: \(http.statusCode), Body: \(respStr)")
        let envelope = (try? decode(BaiduPanResponse.self, from: data))
        if retryOnTokenExpiry, let errno = envelope?.errno, BaiduPanErrorMapping.shouldRefreshToken(errno: errno) {
            Logger.shared.warning(.system, "⚠️ [BaiduPan] Token expired (errno \(errno)), refreshing and retrying POST...")
            try await forceRefresh()
            let freshToken = try await accessToken()
            let updatedURL = replaceTokenInURL(url, with: freshToken)
            return try await performFormPOST(url: updatedURL, body: body, as: type, retryOnTokenExpiry: false)
        }
        if let envelope { try throwIfFailed(envelope) }
        return try decode(type, from: data)
    }

    // MARK: - 令牌

    func accessToken() async throws -> String {
        let token = try await tokenStore.validAccessToken(vaultID: vaultID) { [config] refreshToken in
            guard !config.clientSecret.isEmpty else {
                Logger.shared.error(.system, "❌ [BaiduPan] accessToken refresh failed: clientSecret is empty!")
                throw StorageError.notConfigured
            }
            var c = URLComponents(string: "\(Self.oauthBase)/token")!
            c.queryItems = [
                URLQueryItem(name: "grant_type", value: "refresh_token"),
                URLQueryItem(name: "refresh_token", value: refreshToken),
                URLQueryItem(name: "client_id", value: config.appKey),
                URLQueryItem(name: "client_secret", value: config.clientSecret),
            ]
            var req = URLRequest(url: c.url!)
            req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, _) = try await session.data(for: req)
            let rawResp = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            Logger.shared.info(.system, "📡 [BaiduPan OAuth Refresh Response]: \(rawResp)")
            let payload = try self.decode(BaiduPanTokenResponse.self, from: data)
            if let err = payload.error, !err.isEmpty {
                Logger.shared.error(.system, "❌ [BaiduPan] Token refresh error: \(err), desc: \(payload.error_description ?? "")")
                throw StorageError.authenticationFailed
            }
            guard let newAccess = payload.access_token, !newAccess.isEmpty,
                  let newRefresh = payload.refresh_token, !newRefresh.isEmpty else {
                Logger.shared.error(.system, "❌ [BaiduPan] Incomplete token response in refresh")
                throw StorageError.authenticationFailed
            }
            return (newAccess, newRefresh, payload.expires_in ?? 2592000)
        }
        Logger.shared.info(.system, "🔑 [BaiduPanAPIClient] Acquired valid accessToken (len: \(token.count)) for vault \(vaultID)")
        return token
    }

    /// 强制刷新（收到 token 失效错误码时调用）
    func forceRefresh() async throws {
        Logger.shared.info(.system, "🔄 [BaiduPan] forceRefresh called for vaultID: \(vaultID)")
        tokenStore.forceInvalidateToken(vaultID: vaultID)
        _ = try await tokenStore.validAccessToken(vaultID: vaultID) { [config] refreshToken in
            guard !config.clientSecret.isEmpty else {
                Logger.shared.error(.system, "❌ [BaiduPan] forceRefresh failed: clientSecret is empty!")
                throw StorageError.notConfigured
            }
            var c = URLComponents(string: "\(Self.oauthBase)/token")!
            c.queryItems = [
                URLQueryItem(name: "grant_type", value: "refresh_token"),
                URLQueryItem(name: "refresh_token", value: refreshToken),
                URLQueryItem(name: "client_id", value: config.appKey),
                URLQueryItem(name: "client_secret", value: config.clientSecret),
            ]
            var req = URLRequest(url: c.url!)
            req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, _) = try await session.data(for: req)
            let rawResp = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            Logger.shared.info(.system, "📡 [BaiduPan OAuth ForceRefresh Response]: \(rawResp)")
            let payload = try self.decode(BaiduPanTokenResponse.self, from: data)
            if let err = payload.error, !err.isEmpty {
                Logger.shared.error(.system, "❌ [BaiduPan] Force token refresh error: \(err), desc: \(payload.error_description ?? "")")
                throw StorageError.authenticationFailed
            }
            guard let newAccess = payload.access_token, !newAccess.isEmpty,
                  let newRefresh = payload.refresh_token, !newRefresh.isEmpty else {
                Logger.shared.error(.system, "❌ [BaiduPan] Incomplete token response in forceRefresh")
                throw StorageError.authenticationFailed
            }
            return (newAccess, newRefresh, payload.expires_in ?? 2592000)
        }
    }

    /// 是否需要用户重新扫码授权
    public var requiresReauthorization: Bool { tokenStore.needsReauth(vaultID: vaultID) }

    /// 当前有效 access_token（必要时自动刷新）
    public func currentAccessToken() async throws -> String {
        try await accessToken()
    }

    /// 使指定路径的 dlink 缓存失效（收到 errno 31360 时调用）
    public func invalidateDlink(path: String) {
        tokenStore.invalidateDlink(path: path)
    }

    /// 上传检查点存储（供 StorageClient 复用）
    var checkpoints: BaiduPanTokenStore { tokenStore }

    func apiURL(_ path: String, _ items: [URLQueryItem]) throws -> URL {
        guard let base = URL(string: path) else { throw StorageError.invalidOperation }
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw StorageError.invalidOperation
        }
        c.queryItems = items
        guard let url = c.url else { throw StorageError.invalidOperation }
        return url
    }

    func tokenItem() async throws -> URLQueryItem {
        URLQueryItem(name: "access_token", value: try await accessToken())
    }

    /// 构造已注入 access_token 的请求 URL。
    /// （`await` 不能出现在数组字面量元素中，故统一走这个 async helper。）
    func buildAuthURL(_ path: String, _ items: [URLQueryItem]) async throws -> URL {
        var all = items
        all.append(URLQueryItem(name: "access_token", value: try await accessToken()))
        return try apiURL(path, all)
    }

    // MARK: - 设备码授权

    /// 第一步：申请设备码与用户码
    public func requestDeviceCode() async throws -> BaiduPanDeviceCodeResponse {
        guard !config.appKey.isEmpty else { throw StorageError.notConfigured }
        var c = URLComponents(string: "\(Self.oauthBase)/device/code")!
        c.queryItems = [
            URLQueryItem(name: "response_type", value: "device_code"),
            URLQueryItem(name: "client_id", value: config.appKey),
            URLQueryItem(name: "scope", value: "basic,netdisk"),
        ]
        var req = URLRequest(url: c.url!)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: req)
        return try self.decode(BaiduPanDeviceCodeResponse.self, from: data)
    }

    /// 第三步：用设备码轮询换取 access_token
    public func exchangeDeviceCode(_ deviceCode: String) async throws -> BaiduPanTokenResponse {
        guard !config.clientSecret.isEmpty else { throw StorageError.notConfigured }
        var c = URLComponents(string: "\(Self.oauthBase)/token")!
        c.queryItems = [
            URLQueryItem(name: "grant_type", value: "device_token"),
            URLQueryItem(name: "code", value: deviceCode),
            URLQueryItem(name: "client_id", value: config.appKey),
            URLQueryItem(name: "client_secret", value: config.clientSecret),
        ]
        var req = URLRequest(url: c.url!)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: req)
        return try self.decode(BaiduPanTokenResponse.self, from: data)
    }

    /// 授权成功后落库
    public func persistAuthorized(_ token: BaiduPanTokenResponse) throws {
        guard let refresh = token.refresh_token, !refresh.isEmpty,
              let access = token.access_token, !access.isEmpty else {
            throw StorageError.authenticationFailed
        }
        try tokenStore.saveAuthorized(
            vaultID: vaultID,
            appID: config.appID,
            clientID: config.appKey,
            accessToken: access,
            refreshToken: refresh,
            expiresIn: token.expires_in ?? 2592000
        )
    }

    // MARK: - 列举

    /// `method=list`，按 start/limit 循环分页。
    /// ⚠️ 中途失败必须抛错——返回部分结果会让同步引擎把未列出的本地记录误判为"远端已删除"。
    public func listDirectory(_ logicalPath: String) async throws -> [BaiduPanFileItem] {
        let remote = try fence.resolve(logicalPath)
        var results: [BaiduPanFileItem] = []
        var start = 0
        let pageSize = 1000

        while true {
            let url = try await buildAuthURL("\(Self.apiBase)/xpan/file", [
                URLQueryItem(name: "method", value: "list"),
                URLQueryItem(name: "dir", value: remote),
                URLQueryItem(name: "order", value: "name"),
                URLQueryItem(name: "start", value: String(start)),
                URLQueryItem(name: "limit", value: String(pageSize)),
                URLQueryItem(name: "web", value: "0"),
                URLQueryItem(name: "folder", value: "0"),
            ])
            let resp: BaiduPanListResponse = try await authenticatedGET(url: url, as: BaiduPanListResponse.self)
            let page = resp.list ?? []
            results.append(contentsOf: page)

            if page.count < pageSize { break }
            start += pageSize
            if start > 1_000_000 { throw StorageError.networkError("BaiduPan listing did not terminate") }
        }
        return results
    }

    // MARK: - 元信息 / dlink

    /// 查询文件元信息与 dlink（通过 search / listDirectory / filemetas 官方组合协议实现）
    public func meta(remotePath: String, withDlink: Bool) async throws -> BaiduPanFileItem? {
        try fence.assertWithinFence(remotePath)
        
        // 1. 应用根目录自身始终视为存在并返回虚拟条目
        if remotePath == fence.prefix {
            return BaiduPanFileItem(
                fs_id: 0,
                path: fence.prefix,
                server_filename: fence.appFolderName,
                filename: nil,
                size: 0,
                isdir: 1,
                md5: nil,
                server_ctime: 0,
                server_mtime: 0,
                local_ctime: 0,
                local_mtime: 0,
                category: 6,
                dlink: nil,
                errno: 0
            )
        }

        let parentRemote = (remotePath as NSString).deletingLastPathComponent
        let targetName = (remotePath as NSString).lastPathComponent
        guard !targetName.isEmpty else { return nil }

        var item: BaiduPanFileItem? = nil

        // 2. 尝试利用 search 快速单项检索
        if parentRemote.hasPrefix(fence.prefix) {
            let searchURL = try await buildAuthURL("\(Self.apiBase)/xpan/file", [
                URLQueryItem(name: "method", value: "search"),
                URLQueryItem(name: "dir", value: parentRemote),
                URLQueryItem(name: "key", value: targetName),
                URLQueryItem(name: "recursion", value: "0"),
                URLQueryItem(name: "web", value: "0"),
            ])
            if let resp = try? await authenticatedGET(url: searchURL, as: BaiduPanListResponse.self) {
                item = resp.list?.first(where: { ($0.server_filename ?? $0.filename) == targetName || $0.path == remotePath })
            }
        }

        // 3. 兜底回退：若 search 未命中，通过列举父目录子项查找
        if item == nil && parentRemote.hasPrefix(fence.prefix) {
            let parentLogical = fence.toLogicalPath(parentRemote)
            if let list = try? await listDirectory(parentLogical) {
                item = list.first(where: { $0.name == targetName || $0.path == remotePath })
            }
        }

        // 4. 若上述均未命中（如在只拦截 method=meta 的 Mock 环境下），尝试兼容查询
        if item == nil {
            let legacyURL = try await buildAuthURL("\(Self.apiBase)/xpan/file", [
                URLQueryItem(name: "method", value: "meta"),
                URLQueryItem(name: "path", value: remotePath),
                URLQueryItem(name: "dlink", value: withDlink ? "1" : "0"),
            ])
            if let legacyResp = try? await authenticatedGET(url: legacyURL, as: BaiduPanMetaResponse.self) {
                item = legacyResp.list?.first
            }
        }

        guard let foundItem = item else { return nil }

        // 5. 若需要 dlink 且当前尚未包含 dlink (且非目录)
        if withDlink && !foundItem.isDirectory && (foundItem.dlink ?? "").isEmpty {
            if let fsID = foundItem.fs_id {
                let metasURL = try await buildAuthURL("\(Self.multimediaBase)", [
                    URLQueryItem(name: "method", value: "filemetas"),
                    URLQueryItem(name: "fsids", value: "[\(fsID)]"),
                    URLQueryItem(name: "dlink", value: "1"),
                ])
                if let metaResp = try? await authenticatedGET(url: metasURL, as: BaiduPanMetaResponse.self),
                   let detailed = metaResp.list?.first,
                   let dl = detailed.dlink, !dl.isEmpty {
                    return detailed
                }
            }
            // 兼容降级：若 filemetas 未返回 dlink，尝试从 legacy meta 获取
            let legacyURL = try await buildAuthURL("\(Self.apiBase)/xpan/file", [
                URLQueryItem(name: "method", value: "meta"),
                URLQueryItem(name: "path", value: remotePath),
                URLQueryItem(name: "dlink", value: "1"),
            ])
            if let legacyResp = try? await authenticatedGET(url: legacyURL, as: BaiduPanMetaResponse.self),
               let detailed = legacyResp.list?.first,
               let dl = detailed.dlink, !dl.isEmpty {
                return detailed
            }
        }

        return foundItem
    }

    /// 获取并缓存 dlink（8 小时有效，提前 5 分钟失效）
    public func resolveDlink(remotePath: String) async throws -> String {
        if let cached = tokenStore.cachedDlink(path: remotePath) {
            return cached.dlink
        }
        guard let item = try await meta(remotePath: remotePath, withDlink: true),
              let dlink = item.dlink, !dlink.isEmpty else {
            throw StorageError.notFound
        }
        tokenStore.storeDlink(path: remotePath, dlink: dlink, fsID: item.fs_id ?? 0)
        return dlink
    }

    // MARK: - 创建 / 检查目录

    /// 检查指定远程物理路径是否为有效存在的目录
    public func checkDirectoryExists(remotePath: String) async throws -> Bool {
        try fence.assertWithinFence(remotePath)
        if remotePath == fence.prefix { return true }
        let url = try await buildAuthURL("\(Self.apiBase)/xpan/file", [
            URLQueryItem(name: "method", value: "list"),
            URLQueryItem(name: "dir", value: remotePath),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "folder", value: "0"),
        ])
        do {
            let resp: BaiduPanListResponse = try await authenticatedGET(url: url, as: BaiduPanListResponse.self)
            return (resp.errno ?? 0) == 0
        } catch StorageError.notFound {
            return false
        } catch {
            return false
        }
    }

    @discardableResult
    public func createFolder(remotePath: String, rtype: Int = 1) async throws -> UInt64? {
        try fence.assertWithinFence(remotePath)
        let url = try await buildAuthURL("\(Self.apiBase)/xpan/file", [
            URLQueryItem(name: "method", value: "create"),
            ])
        let resp: BaiduPanCreateResponse = try await formPOST(url: url, body: [
            "path": remotePath,
            "isdir": "1",
            "rtype": String(rtype),
        ], as: BaiduPanCreateResponse.self)
        return resp.fs_id
    }

    // MARK: - 文件管理（复制 / 移动 / 重命名 / 删除）

    struct FileManagerEntry: Encodable {
        let path: String
        let dest: String?
        let newname: String?
    }

    /// 单条操作强制同步（async=0），以便直接拿到 `info[].errno`。
    /// ⚠️ 与 WebDAV 207 同样的陷阱：顶层 errno == 0 **不代表**全部成功，必须逐项校验。
    func fileManager(opera: String, entries: [FileManagerEntry], ondup: String?) async throws {
        try limiter.consume()
        var filelist: [[String: String]] = []
        for e in entries {
            var dict: [String: String] = ["path": e.path]
            if let dest = e.dest { dict["dest"] = dest }
            if let newname = e.newname { dict["newname"] = newname }
            filelist.append(dict)
        }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: filelist),
              let json = String(data: jsonData, encoding: .utf8) else {
            throw StorageError.invalidOperation
        }

        let url = try await buildAuthURL("\(Self.apiBase)/xpan/file", [
            URLQueryItem(name: "method", value: "filemanager"),
            URLQueryItem(name: "opera", value: opera),
        ])
        var req = makeRequest(url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body: [String: String] = ["async": "0", "filelist": json]
        if let ondup { body["ondup"] = ondup }
        var components = URLComponents()
        components.queryItems = body.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw StorageError.networkError("Invalid response") }
        guard (200...299).contains(http.statusCode) else {
            throw StorageError.serverError(statusCode: http.statusCode, message: "HTTP \(http.statusCode)")
        }
        let envelope = try decode(BaiduPanResponse.self, from: data)
        if let errno = envelope.errno, errno != 0, BaiduPanErrorMapping.shouldRefreshToken(errno: errno) {
            try await forceRefresh()
            return try await fileManager(opera: opera, entries: entries, ondup: ondup)
        }
        try throwIfFailed(envelope)

        let resp = try decode(BaiduPanFileManagerResponse.self, from: data)
        for item in resp.info ?? [] {
            if let e = item.errno, e != 0 {
                // 逐项失败：映射为对应错误，保留该路径信息
                var mapped = BaiduPanErrorMapping.map(errno: e, errmsg: envelope.errmsg)
                if case .serverError(let code, let message) = mapped {
                    mapped = .serverError(statusCode: code, message: "\(message) [\(item.path ?? "?")]")
                }
                throw mapped
            }
        }
    }

    public func move(from source: String, to dest: String, newname: String?) async throws {
        try await fileManager(opera: "move", entries: [.init(path: source, dest: dest, newname: newname)], ondup: "fail")
    }

    public func copy(from source: String, to dest: String, newname: String?) async throws {
        try await fileManager(opera: "copy", entries: [.init(path: source, dest: dest, newname: newname)], ondup: "fail")
    }

    public func rename(path: String, newname: String) async throws {
        try await fileManager(opera: "rename", entries: [.init(path: path, dest: nil, newname: newname)], ondup: "fail")
    }

    public func delete(remotePath: String) async throws {
        try fence.assertWithinFence(remotePath)
        try limiter.consume()
        let encoded = try JSONSerialization.data(withJSONObject: [remotePath])
        guard let json = String(data: encoded, encoding: .utf8) else { throw StorageError.invalidOperation }
        let url = try await buildAuthURL("\(Self.apiBase)/xpan/file", [
            URLQueryItem(name: "method", value: "filemanager"),
            URLQueryItem(name: "opera", value: "delete"),
        ])
        var req = makeRequest(url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "async", value: "0"),
            URLQueryItem(name: "filelist", value: json),
        ]
        req.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw StorageError.networkError("filemanager delete failed")
        }
        let envelope = try decode(BaiduPanResponse.self, from: data)
        try throwIfFailed(envelope)
        let resp = try decode(BaiduPanFileManagerResponse.self, from: data)
        for item in resp.info ?? [] {
            if let e = item.errno, e != 0 {
                throw BaiduPanErrorMapping.map(errno: e, errmsg: envelope.errmsg)
            }
        }
    }

    // MARK: - 用户信息

    public func userInfo() async throws -> BaiduPanUserInfoResponse {
        let url = try await buildAuthURL("\(Self.apiBase)/xpan/nas", [
            URLQueryItem(name: "method", value: "uinfo"),
            URLQueryItem(name: "vip_version", value: "v2"),
        ])
        let resp = try await authenticatedGET(url: url, as: BaiduPanUserInfoResponse.self)
        let tier = BaiduPanTier(vipType: resp.vip_type ?? 0)
        let quota = try? await quota()
        tokenStore.storeUserInfo(
            vaultID: vaultID,
            uk: resp.uk,
            baiduName: resp.baidu_name,
            netdiskName: resp.netdisk_name,
            vipType: tier.rawValue,
            total: quota?.total,
            used: quota?.used
        )
        return resp
    }

    /// 容量查询走 `/api/quota`，**不带** method 参数
    public func quota() async throws -> BaiduPanQuotaResponse {
        let url = try await buildAuthURL(Self.quotaBase, [])
        return try await authenticatedGET(url: url, as: BaiduPanQuotaResponse.self)
    }

    public func cachedTier() -> BaiduPanTier? { tokenStore.cachedTier(vaultID: vaultID) }
}