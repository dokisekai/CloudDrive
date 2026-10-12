//
//  BaiduPanAPIClient+Upload.swift
//  CloudDriveStorage
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  上传编排：locateupload → precreate → superfile2(分片) → create
//
//  官方注意事项：
//  - 上传域名由 locateupload 动态下发，expire 仅 60 秒，**禁止缓存**
//  - precreate 的 path/size/isdir/rtype/block_list 必须与 create 阶段逐字一致
//  - 只上传 precreate 返回的 block_list 指定的分片（秒传/断点续传）
//  - 单文件分片数不得超过 1024
//

import Foundation
import CloudDriveContracts
import CryptoKit

extension BaiduPanAPIClient {

    /// 单文件上传总流程。
    /// - Parameters:
    ///   - mode: `.createIfAbsent` → rtype=1（冲突重命名）；`.replace`/`.forceOverwrite` → rtype=3（覆盖）
    ///   - progress: 0...1
    /// - Returns: 合成 ETag（百度不提供强 ETag，仅供乐观并发检测）
    @discardableResult
    public func uploadFile(
        localURL: URL,
        remotePath: String,
        tier: BaiduPanTier,
        mode: StorageWriteMode,
        progress: @escaping (Double) -> Void
    ) async throws -> String {

        try fence.assertWithinFence(remotePath)

        let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0

        guard fileSize <= tier.maxFileSize else {
            throw StorageError.notSupported(
                "文件 \(fileSize) B 超过当前会员档位上限 \(tier.maxFileSize) B（errno 31365）"
            )
        }

        // 分片数不得超过 1024
        let sliceSize = tier.sliceSize
        let sliceCount = fileSize == 0 ? 1 : Int((fileSize + sliceSize - 1) / sliceSize)
        guard sliceCount <= 1024 else {
            throw StorageError.notSupported("分片数 \(sliceCount) 超过上限 1024")
        }

        let rtype: Int = (mode == .createIfAbsent) ? 1 : 3

        // 1) 计算全部分片 MD5
        let digests = try Self.sliceMD5s(of: localURL, sliceSize: sliceSize, sliceCount: sliceCount)
        let contentMD5 = (try? Self.fileMD5(of: localURL)) ?? ""
        let sliceMD5 = (try? Self.headMD5(of: localURL, length: min(256 * 1024, max(fileSize, 1)))) ?? ""

        // 2) precreate（含断点恢复：命中已有检查点时携带原 uploadid）
        let checkpointKey = remotePath
        let existing = tokenStore.loadCheckpoint(path: checkpointKey)

        let (uploadid, missingSlices) = try await precreate(
            path: remotePath,
            size: fileSize,
            rtype: rtype,
            blockList: digests,
            contentMD5: contentMD5,
            sliceMD5: sliceMD5,
            resumeUploadID: existing?.uploadid
        )

        guard !missingSlices.isEmpty else {
            // 秒传命中：全部已在云端，直接进入 create
            progress(0.95)
            return try await createFile(
                remotePath: remotePath,
                size: fileSize,
                rtype: rtype,
                uploadID: uploadid,
                blockList: digests
            )
        }

        // 3) 获取上传域名（60 秒有效，禁止缓存）
        let host = try await locateUpload(path: remotePath, uploadID: uploadid)
        var resultMD5s = digests

        var checkpoint = BaiduPanUploadCheckpoint(
            path: remotePath,
            uploadid: uploadid,
            size: fileSize,
            sliceSize: sliceSize,
            rtype: rtype,
            blockMD5: digests,
            completedSlices: [],
            sliceMD5s: digests,
            state: .uploading
        )
        tokenStore.saveCheckpoint(checkpoint)

        let uploadedBytes = (sliceCount - missingSlices.count) * Int(sliceSize)
        for (index, seq) in missingSlices.enumerated() {
            let remoteMD5 = try await uploadSlice(
                host: host,
                path: remotePath,
                uploadID: uploadid,
                seq: seq,
                localURL: localURL,
                offset: checkpoint.sliceOffset(seq),
                length: checkpoint.sliceLength(seq)
            )
            resultMD5s[seq] = remoteMD5
            checkpoint.completedSlices.append(seq)
            checkpoint.state = .uploading
            tokenStore.saveCheckpoint(checkpoint)
            let done = uploadedBytes + (index + 1) * Int(checkpoint.sliceLength(seq))
            progress(fileSize == 0 ? 0.9 : min(0.95, Double(done) / Double(fileSize)))
        }

        checkpoint.state = .merging
        tokenStore.saveCheckpoint(checkpoint)

        // 5) create 合并
        let etag = try await createFile(
            remotePath: remotePath,
            size: fileSize,
            rtype: rtype,
            uploadID: uploadid,
            blockList: resultMD5s
        )
        tokenStore.clearCheckpoint(path: checkpointKey)
        progress(1.0)
        return etag
    }

    // MARK: - 四段式

    private func precreate(
        path: String,
        size: Int64,
        rtype: Int,
        blockList: [String],
        contentMD5: String,
        sliceMD5: String,
        resumeUploadID: String?
    ) async throws -> (uploadID: String, missingBlockList: [Int]) {
        let url = try await buildAuthURL("\(Self.apiBase)/xpan/file", [
            URLQueryItem(name: "method", value: "precreate"),
        ])
        var body: [String: String] = [
            "path": path,
            "size": String(size),
            "isdir": "0",
            "autoinit": "1",
            "rtype": String(rtype),
            "block_list": Self.jsonStringArray(blockList),
        ]
        if !contentMD5.isEmpty { body["content-md5"] = contentMD5 }
        if !sliceMD5.isEmpty { body["slice-md5"] = sliceMD5 }
        if let resumeUploadID, !resumeUploadID.isEmpty {
            body["uploadid"] = resumeUploadID
        }
        let resp: BaiduPanPrecreateResponse = try await formPOST(url: url, body: body, as: BaiduPanPrecreateResponse.self)
        guard let uploadid = resp.uploadid, !uploadid.isEmpty else {
            throw StorageError.invalidOperation
        }
        let missing = resp.block_list ?? Array(0..<blockList.count)
        return (uploadid, missing)
    }

    /// 获取上传域名（expire 60 秒，必须现取现用）
    private func locateUpload(path: String, uploadID: String) async throws -> String {
        try limiter.consume()
        let token = try await accessToken()
        let appIDValue = config.appID.isEmpty ? "250528" : config.appID
        let url = try apiURL("\(Self.locateUploadBase)", [
            URLQueryItem(name: "method", value: "locateupload"),
            URLQueryItem(name: "appid", value: appIDValue),
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "uploadid", value: uploadID),
            URLQueryItem(name: "upload_version", value: "2.0"),
        ])
        let req = makeRequest(url)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw StorageError.networkError("locateupload failed")
        }
        let resp = try decode(BaiduPanLocateUploadResponse.self, from: data)
        if let code = resp.error_code, code != 0 {
            throw BaiduPanErrorMapping.map(errno: code, errmsg: resp.error_msg)
        }
        var candidates: [String] = []
        if let h = resp.host, !h.isEmpty {
            candidates.append(h)
        }
        for s in (resp.servers ?? []) + (resp.bak_servers ?? []) {
            if !s.server.isEmpty {
                candidates.append(s.server)
            }
        }
        guard let rawHost = candidates.first(where: { $0.hasPrefix("https://") })
                ?? candidates.first else {
            throw StorageError.networkError("locateupload returned no usable host")
        }
        let host = (rawHost.hasPrefix("http://") || rawHost.hasPrefix("https://")) ? rawHost : "https://\(rawHost)"
        return host
    }

    /// 上传单个分片
    private func uploadSlice(
        host: String,
        path: String,
        uploadID: String,
        seq: Int,
        localURL: URL,
        offset: Int64,
        length: Int64
    ) async throws -> String {
        try limiter.consume()
        let token = try await accessToken()
        let url = try apiURL("\(host)/rest/2.0/pcs/superfile2", [
            URLQueryItem(name: "method", value: "upload"),
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "type", value: "tmpfile"),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "uploadid", value: uploadID),
            URLQueryItem(name: "partseq", value: String(seq)),
        ])
        let boundary = "----CloudDriveBaiduPan\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"part-\(seq)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let chunk = (try handle.read(upToCount: Int(length))) ?? Data()
        body.append(chunk)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = makeRequest(url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.upload(for: req, from: body)
        guard let http = response as? HTTPURLResponse else { throw StorageError.networkError("Invalid response") }
        guard (200...299).contains(http.statusCode) else {
            throw StorageError.serverError(statusCode: http.statusCode, message: "slice \(seq) upload failed")
        }
        let resp = try decode(BaiduPanSliceUploadResponse.self, from: data)
        if let errno = resp.errno, errno != 0 {
            throw BaiduPanErrorMapping.map(errno: errno, errmsg: nil)
        }
        return resp.md5 ?? ""
    }

    /// 合并分片生成文件
    private func createFile(
        remotePath: String,
        size: Int64,
        rtype: Int,
        uploadID: String,
        blockList: [String]
    ) async throws -> String {
        let url = try await buildAuthURL("\(Self.apiBase)/xpan/file", [
            URLQueryItem(name: "method", value: "create"),
            ])
        let resp: BaiduPanCreateResponse = try await formPOST(url: url, body: [
            "path": remotePath,
            "size": String(size),
            "isdir": "0",
            "rtype": String(rtype),
            "uploadid": uploadID,
            "block_list": Self.jsonStringArray(blockList),
        ], as: BaiduPanCreateResponse.self)
        let fsID = resp.fs_id ?? 0
        let mtime = resp.mtime ?? 0
        return "bp-\(fsID)-\(size)-\(mtime)"
    }

    // MARK: - 摘要工具

    private static func jsonStringArray(_ items: [String]) -> String {
        let encoded = items.map { "\"\($0)\"" }.joined(separator: ",")
        return "[\(encoded)]"
    }

    private static func sliceMD5s(of url: URL, sliceSize: Int64, sliceCount: Int) throws -> [String] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var out: [String] = []
        out.reserveCapacity(sliceCount)
        for i in 0..<sliceCount {
            try handle.seek(toOffset: UInt64(Int64(i) * sliceSize))
            let data = (try handle.read(upToCount: Int(sliceSize))) ?? Data()
            out.append(md5Hex(data))
        }
        return out
    }

    private static func headMD5(of url: URL, length: Int64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = (try handle.read(upToCount: Int(length))) ?? Data()
        return md5Hex(data)
    }

    private static func fileMD5(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while autoreleasepool(invoking: {
            guard let chunk = try? handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else {
                return false
            }
            hasher.update(data: chunk)
            return true
        }) {}
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func md5Hex(_ data: Data) -> String {
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}