//
//  BaiduPanStorageClient.swift
//  CloudDriveStorage
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  百度网盘存储客户端 —— 实现统一 StorageClient 协议
//  官方文档: https://pan.baidu.com/union/doc/
//

import Foundation
import CloudDriveContracts
import CloudDriveSupport

public class BaiduPanStorageClient: StorageClient {

    public let config: BaiduPanStorageConfig
    public let api: BaiduPanAPIClient
    private let session: URLSession
    private let vaultID: String

    /// 会员档位决定分片大小与单文件上限（错误码 31365），必须运行时解析
    private var resolvedTier: BaiduPanTier

    /// 百度网盘不提供 HTTP ETag，也没有 If-Match / If-None-Match 能力
    public var requiresETagForUpdate: Bool { false }

    public var capabilities: StorageCapabilities {
        StorageCapabilities(
            supportsResumableDownload: true,   // dlink 支持 Range
            supportsResumableUpload: true,     // precreate 返回缺片清单
            supportsFastUpload: true,          // slice-md5 + content-md5 秒传
            supportsServerSideMove: true,      // filemanager opera=move
            supportsServerSideCopy: true,      // filemanager opera=copy
            maxUploadFileSize: resolvedTier.maxFileSize,
            preferredSliceSize: resolvedTier.sliceSize
        )
    }

    public init(
        config: BaiduPanStorageConfig,
        vaultID: String = "default",
        session: URLSession = .shared,
        tokenStore: BaiduPanTokenStore = BaiduPanTokenStore(),
        cachedTier: BaiduPanTier? = nil
    ) {
        self.config = config
        self.vaultID = vaultID
        self.session = session
        self.resolvedTier = cachedTier ?? .standard
        self.api = BaiduPanAPIClient(
            config: config,
            vaultID: vaultID,
            session: session,
            tokenStore: tokenStore
        )
    }

    /// 刷新会员档位（连接建立后调用一次）
    @discardableResult
    public func resolveTier() async -> BaiduPanTier {
        if let cached = api.cachedTier() {
            resolvedTier = cached
            return cached
        }
        if let info = try? await api.userInfo() {
            let tier = BaiduPanTier(vipType: info.vip_type ?? 0)
            resolvedTier = tier
            return tier
        }
        return resolvedTier
    }

    public var requiresReauthorization: Bool { api.requiresReauthorization }

    // MARK: - 列举

    public func listDirectory(path: String) async throws -> [StorageResource] {
        let items = try await api.listDirectory(path)
        return items.compactMap { item in
            guard let remotePath = item.path, !item.name.isEmpty else { return nil }
            return StorageResource(
                path: api.fence.toLogicalPath(remotePath),
                displayName: item.name,
                isDirectory: item.isDirectory,
                contentLength: item.byteSize,
                contentType: nil,
                creationDate: item.createdAt,
                lastModified: item.modifiedAt,
                etag: item.synthesizedETag()
            )
        }
    }

    // MARK: - 下载

    public func downloadFile(path: String, to destinationURL: URL, progress: @escaping (Double) -> Void) async throws {
        try await downloadFile(path: path, to: destinationURL, expectedETag: nil, maximumBytes: .max, progress: progress)
    }

    @discardableResult
    public func downloadFile(
        path: String,
        to destinationURL: URL,
        expectedETag: String?,
        progress: @escaping (Double) -> Void
    ) async throws -> String? {
        try await downloadFile(path: path, to: destinationURL, expectedETag: expectedETag, maximumBytes: .max, progress: progress)
    }

    @discardableResult
    public func downloadFile(
        path: String,
        to destinationURL: URL,
        expectedETag: String?,
        maximumBytes: Int64,
        progress: @escaping (Double) -> Void
    ) async throws -> String? {
        if expectedETag != nil {
            // 若显式传入 expectedETag，仅在云端明确不存在该文件时阻断
            let current = try await currentETag(path: path)
            if current == nil {
                throw StorageError.notFound
            }
        }
        let remote = try api.fence.resolve(path)
        _ = try await downloadRemote(
            remotePath: remote,
            range: nil,
            to: destinationURL,
            maximumBytes: maximumBytes,
            progress: progress
        )
        return try await currentETag(path: path)
    }

    public func downloadRange(path: String, range: ClosedRange<Int64>) async throws -> Data {
        try await downloadRange(path: path, range: range, expectedETag: nil)
    }

    public func downloadRange(path: String, range: ClosedRange<Int64>, expectedETag: String?) async throws -> Data {
        if expectedETag != nil {
            let current = try await currentETag(path: path)
            if current == nil {
                throw StorageError.notFound
            }
        }
        let remote = try api.fence.resolve(path)
        let length = max(0, range.upperBound - range.lowerBound + 1)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("bp_range_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        _ = try await downloadRemote(
            remotePath: remote,
            range: range,
            to: tempURL,
            maximumBytes: length,
            progress: { _ in }
        )
        guard let data = try? Data(contentsOf: tempURL) else { throw StorageError.notFound }
        return data
    }

    /// 通过 dlink 下载。`range == nil` 表示整文件。
    ///
    /// ⚠️ dlink 签名位于 query string 内，**禁止**用 URLComponents 重新编码（否则 errno 31362）。
    private func downloadRemote(
        remotePath: String,
        range: ClosedRange<Int64>?,
        to destinationURL: URL,
        maximumBytes: Int64,
        progress: @escaping (Double) -> Void
    ) async throws -> UInt64 {

        var attempt = 0

        while true {
            attempt += 1
            guard attempt <= 3 else {
                throw StorageError.networkError("BaiduPan dlink repeatedly failing")
            }

            // 循环内获取 dlink，每次重试均拉取最新或刷新后的链接
            var dlink = try await api.resolveDlink(remotePath: remotePath)

            // 拼接 token：字符串直拼，不重新编码
            if let token = try? await api.currentAccessToken() {
                dlink = dlink.contains("?") ? "\(dlink)&access_token=\(token)" : "\(dlink)?access_token=\(token)"
            }
            guard let url = URL(string: dlink) else {
                throw StorageError.invalidOperation
            }

            var req = URLRequest(url: url)
            req.setValue(BaiduPanAPIClient.userAgent, forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 300
            if let range {
                req.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
            }

            // tempURL 需在 do 之前声明，供 catch 清理残留下载文件
            var tempURLToClean: URL?
            do {
                let delegate = AsyncDownloadProgressDelegate(onProgress: progress)
                let (tempURL, response) = try await session.download(for: req, delegate: delegate)
                tempURLToClean = tempURL
                guard let http = response as? HTTPURLResponse else {
                    throw StorageError.networkError("Invalid response")
                }

                // 百度 CDN 节点防盗链或链接过期常返回 HTTP 401/403/404/410，触发主动失效并重新申请换链
                if [401, 403, 404, 410].contains(http.statusCode) && attempt < 3 {
                    if let tempURLToClean { try? FileManager.default.removeItem(at: tempURLToClean) }
                    api.invalidateDlink(path: remotePath)
                    continue
                }

                guard (200...299).contains(http.statusCode) else {
                    throw StorageError.serverError(statusCode: http.statusCode, message: "HTTP \(http.statusCode)")
                }

                // 百度网盘业务错误即使在 HTTP 200 时，也可能返回包含 errno 的 JSON 响应体（如 31360 dlink 已过期）
                if let body = try? Data(contentsOf: tempURL),
                   let envelope = try? JSONDecoder().decode(BaiduPanResponse.self, from: body),
                   let errno = envelope.errno, errno != 0 {
                    try? FileManager.default.removeItem(at: tempURL)
                    if (errno == BaiduPanErrorMapping.dlinkExpiredCode || errno == 31066 || errno == -9) && attempt < 3 {
                        api.invalidateDlink(path: remotePath)
                        continue
                    }
                    throw BaiduPanErrorMapping.map(errno: errno, errmsg: envelope.errmsg)
                }

                let size = Int64((try? tempURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1)
                if maximumBytes != .max, size > maximumBytes {
                    try? FileManager.default.removeItem(at: tempURL)
                    throw StorageError.notSupported("Download exceeded expected payload size")
                }

                let parentDir = destinationURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
                let staging = parentDir.appendingPathComponent(".clouddrive_bp_" + UUID().uuidString)
                try? FileManager.default.removeItem(at: staging)
                try FileManager.default.moveItem(at: tempURL, to: staging)
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: staging)
                } else {
                    try FileManager.default.moveItem(at: staging, to: destinationURL)
                }
                progress(1.0)
                return UInt64(max(0, size))
            } catch let error as StorageError {
                if let tempURLToClean { try? FileManager.default.removeItem(at: tempURLToClean) }
                throw error
            } catch {
                if let tempURLToClean { try? FileManager.default.removeItem(at: tempURLToClean) }
                if attempt < 3 {
                    api.invalidateDlink(path: remotePath)
                    continue
                }
                throw StorageError.networkError(error.localizedDescription)
            }
        }
    }

    // MARK: - 上传

    public func uploadFile(localURL: URL, to remotePath: String, progress: @escaping (Double) -> Void) async throws {
        try await uploadFile(localURL: localURL, to: remotePath, mode: .forceOverwrite, progress: progress)
    }

    @discardableResult
    public func uploadFile(
        localURL: URL,
        to remotePath: String,
        expectedETag: String?,
        progress: @escaping (Double) -> Void
    ) async throws -> String? {
        if let expectedETag {
            return try await uploadFile(localURL: localURL, to: remotePath, mode: .replace(expectedETag: expectedETag), progress: progress)
        }
        return try await uploadFile(localURL: localURL, to: remotePath, mode: .forceOverwrite, progress: progress)
    }

    @discardableResult
    public func uploadFile(
        localURL: URL,
        to remotePath: String,
        mode: StorageWriteMode,
        progress: @escaping (Double) -> Void
    ) async throws -> String? {
        if resolvedTier == .standard, let tier = api.cachedTier() {
            resolvedTier = tier
        }

        switch mode {
        case .createIfAbsent:
            if try await exists(path: remotePath) {
                throw StorageError.serverError(statusCode: 412, message: "Target already exists")
            }
        case .replace(let expectedETag):
            // 百度网盘无条件写：只能靠写前比对合成 ETag 做乐观并发检测
            let current = try await currentETag(path: remotePath)
            guard current == expectedETag else {
                throw StorageError.serverError(
                    statusCode: 412,
                    message: "BaiduPan revision changed: expected \(expectedETag), got \(current ?? "none")"
                )
            }
        case .forceOverwrite:
            break
        }

        let remote = try api.fence.resolve(remotePath)
        return try await api.uploadFile(
            localURL: localURL,
            remotePath: remote,
            tier: resolvedTier,
            mode: mode,
            progress: progress
        )
    }

    // MARK: - 目录 / 删除 / 移动 / 复制

    public func createDirectory(path: String) async throws {
        let remote = try api.fence.resolve(path)
        _ = try await api.createFolder(remotePath: remote, rtype: 1)
    }

    public func delete(path: String) async throws {
        let remote = try api.fence.resolve(path)
        try await api.delete(remotePath: remote)
    }

    public func delete(path: String, expectedETag: String?) async throws {
        if let expectedETag {
            let current = try await currentETag(path: path)
            guard current == expectedETag else {
                throw StorageError.serverError(statusCode: 412, message: "BaiduPan revision changed")
            }
        }
        try await delete(path: path)
    }

    public func move(from sourcePath: String, to destinationPath: String) async throws {
        let source = try api.fence.resolve(sourcePath)
        let dest = try api.fence.resolve(destinationPath)
        let destDir = (dest as NSString).deletingLastPathComponent
        let newname = (dest as NSString).lastPathComponent
        guard BaiduPanPathFence.isValidFileName(newname) else { throw StorageError.invalidOperation }
        try await api.move(from: source, to: destDir, newname: newname)
    }

    public func move(from sourcePath: String, to destinationPath: String, expectedETag: String?) async throws {
        if let expectedETag {
            let current = try await currentETag(path: sourcePath)
            guard current == expectedETag else {
                throw StorageError.serverError(statusCode: 412, message: "BaiduPan revision changed")
            }
        }
        try await move(from: sourcePath, to: destinationPath)
    }

    @discardableResult
    public func moveWithRevision(from sourcePath: String, to destinationPath: String, expectedETag: String?) async throws -> String? {
        try await move(from: sourcePath, to: destinationPath, expectedETag: expectedETag)
        return try await currentETag(path: destinationPath)
    }

    public func copy(from sourcePath: String, to destinationPath: String) async throws {
        let source = try api.fence.resolve(sourcePath)
        let dest = try api.fence.resolve(destinationPath)
        let destDir = (dest as NSString).deletingLastPathComponent
        let newname = (dest as NSString).lastPathComponent
        guard BaiduPanPathFence.isValidFileName(newname) else { throw StorageError.invalidOperation }
        try await api.copy(from: source, to: destDir, newname: newname)
    }

    @discardableResult
    public func copy(from sourcePath: String, to destinationPath: String, expectedETag: String?) async throws -> String? {
        if let expectedETag {
            let current = try await currentETag(path: sourcePath)
            guard current == expectedETag else {
                throw StorageError.serverError(statusCode: 412, message: "BaiduPan revision changed")
            }
        }
        try await copy(from: sourcePath, to: destinationPath)
        return try await currentETag(path: destinationPath)
    }

    // MARK: - 查询

    public func exists(path: String) async throws -> Bool {
        let remote: String
        do {
            remote = try api.fence.resolve(path)
        } catch {
            return false
        }

        // 1. 应用根目录自身始终视为存在
        if remote == api.fence.prefix {
            return true
        }

        let name = (remote as NSString).lastPathComponent
        let looksLikeFile = name.contains(".") && !name.hasPrefix(".")

        // 2. 带有常规扩展名时优先探测 meta 普通文件，减少目录探测的失败开销
        if looksLikeFile {
            if let item = try? await api.meta(remotePath: remote, withDlink: false) {
                if (item.errno == nil || item.errno == 0) && item.path != nil {
                    return true
                }
            }
            if (try? await api.checkDirectoryExists(remotePath: remote)) == true {
                return true
            }
        } else {
            // 3. 否则优先探测目录 (method=list&dir=remote&limit=1)
            if (try? await api.checkDirectoryExists(remotePath: remote)) == true {
                return true
            }
            if let item = try? await api.meta(remotePath: remote, withDlink: false) {
                if (item.errno == nil || item.errno == 0) && item.path != nil {
                    return true
                }
            }
        }

        // 4. 列举父目录子项：标准 method=list 兜底校验（支持文件与文件夹）
        if await checkParentContains(remotePath: remote) {
            return true
        }

        return false
    }

    private func checkParentContains(remotePath: String) async -> Bool {
        guard remotePath != api.fence.prefix else { return true }
        let parentRemote = (remotePath as NSString).deletingLastPathComponent
        let targetName = (remotePath as NSString).lastPathComponent
        guard !targetName.isEmpty, parentRemote.hasPrefix(api.fence.prefix) else { return false }
        
        let parentLogical = api.fence.toLogicalPath(parentRemote)
        guard let items = try? await api.listDirectory(parentLogical) else { return false }
        return items.contains { $0.name == targetName }
    }

    public func testConnection() async throws -> Bool {
        // 1. 尝试拉取用户信息（用于更新会员档位，best-effort）
        if let info = try? await api.userInfo() {
            if let tier = BaiduPanTier(rawValue: info.vip_type ?? 0) {
                resolvedTier = tier
            }
        }
        // 2. 尝试拉取容量（best-effort）
        _ = try? await api.quota()

        // 3. 最核心的连通性与权限验证：列举应用根目录（检验 Token 是否有效、是否可操作围栏目录）
        _ = try await api.listDirectory("/")
        return true
    }

    /// 读取路径当前的合成 ETag（不存在返回 nil）
    private func currentETag(path: String) async throws -> String? {
        let remote: String
        do {
            remote = try api.fence.resolve(path)
        } catch {
            return nil
        }
        guard let item = try? await api.meta(remotePath: remote, withDlink: false) else { return nil }
        return item.synthesizedETag()
    }
}