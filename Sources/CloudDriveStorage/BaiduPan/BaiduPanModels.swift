//
//  BaiduPanModels.swift
//  CloudDriveStorage
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  百度网盘开放平台响应模型
//

import Foundation
import CloudDriveContracts

// MARK: - 通用

/// 百度网盘统一错误响应体：`{ errno, errmsg, ... }`
/// ⚠️ errno 是业务错误码，**不是** HTTP 状态码。
public struct BaiduPanResponse: Decodable {
    let errno: Int?
    let errmsg: String?
    let show_msg: String?
}

// MARK: - 设备码授权

public struct BaiduPanDeviceCodeResponse: Decodable, Sendable {
    public let device_code: String
    public let user_code: String
    public let verification_url: String
    public let qrcode_url: String?
    public let expires_in: Int
    public let interval: Int

    public init(
        device_code: String,
        user_code: String,
        verification_url: String,
        qrcode_url: String? = nil,
        expires_in: Int = 300,
        interval: Int = 5
    ) {
        self.device_code = device_code
        self.user_code = user_code
        self.verification_url = verification_url
        self.qrcode_url = qrcode_url
        self.expires_in = expires_in
        self.interval = interval
    }
}

public struct BaiduPanTokenResponse: Decodable, Sendable {
    public let access_token: String?
    public let refresh_token: String?
    public let expires_in: Int?
    public let scope: String?
    public let error: String?
    public let error_description: String?

    public init(
        access_token: String? = nil,
        refresh_token: String? = nil,
        expires_in: Int? = 2592000,
        scope: String? = nil,
        error: String? = nil,
        error_description: String? = nil
    ) {
        self.access_token = access_token
        self.refresh_token = refresh_token
        self.expires_in = expires_in
        self.scope = scope
        self.error = error
        self.error_description = error_description
    }
}

// MARK: - 文件列举 / 元信息

public struct BaiduPanFileItem: Decodable {
    let fs_id: UInt64?
    let path: String?
    let server_filename: String?
    let filename: String?
    let size: UInt64?
    let isdir: Int?
    let md5: String?
    let server_ctime: UInt64?
    let server_mtime: UInt64?
    let local_ctime: UInt64?
    let local_mtime: UInt64?
    let category: Int?
    let dlink: String?
    /// 批量查询时单个条目的错误码
    let errno: Int?

    var isDirectory: Bool { (isdir ?? 0) == 1 }
    var name: String { server_filename ?? filename ?? "" }
    var byteSize: Int64 { Int64(size ?? 0) }
    var modifiedAt: Date? {
        guard let ts = server_mtime ?? local_mtime else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts))
    }
    var createdAt: Date? {
        guard let ts = server_ctime ?? local_ctime else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts))
    }

    /// 百度网盘不返回 HTTP ETag；用不变标识 fs_id + size + mtime 合成一个。
    /// **仅用于乐观并发检测，不可用于内容校验。**
    func synthesizedETag() -> String {
        if isDirectory {
            return "bp-dir-\(fs_id ?? 0)"
        }
        return "bp-\(fs_id ?? 0)-\(size ?? 0)-\(server_mtime ?? 0)"
    }
}

public struct BaiduPanListResponse: Decodable {
    let errno: Int?
    let errmsg: String?
    let list: [BaiduPanFileItem]?
    let has_more: Int?
    let cursor: Int?
    let info: [BaiduPanFileItem]?
}

/// 查询文件信息（单文件 `meta` / 路径批量 `filemetas`）
public struct BaiduPanMetaResponse: Decodable {
    let errno: Int?
    let errmsg: String?
    let list: [BaiduPanFileItem]?
    let info: [BaiduPanFileItem]?
}

// MARK: - 上传

public struct BaiduPanPrecreateResponse: Decodable {
    let errno: Int?
    let errmsg: String?
    let path: String?
    let uploadid: String?
    let return_type: Int?
    /// 需要上传的分片序号列表；为空表示秒传命中，文件已存在
    let block_list: [Int]?
}

public struct BaiduPanSliceUploadResponse: Decodable {
    let errno: Int?
    let md5: String?
}

public struct BaiduPanCreateResponse: Decodable {
    let errno: Int?
    let errmsg: String?
    let fs_id: UInt64?
    let md5: String?
    let server_filename: String?
    let path: String?
    let size: UInt64?
    let ctime: UInt64?
    let mtime: UInt64?
    let isdir: Int?
}

public struct BaiduPanLocateUploadResponse: Decodable {
    struct Server: Decodable { let server: String }
    let error_code: Int?
    let error_msg: String?
    let host: String?
    let expire: Int?
    let servers: [Server]?
    let bak_servers: [Server]?
    let quic_servers: [Server]?
}

// MARK: - filemanager

public struct BaiduPanFileManagerResponse: Decodable {
    struct Info: Decodable {
        let errno: Int?
        let path: String?
    }
    let errno: Int?
    let errmsg: String?
    let info: [Info]?
}

// MARK: - 用户信息 / 容量

public struct BaiduPanUserInfoResponse: Decodable {
    let errno: Int?
    let errmsg: String?
    let baidu_name: String?
    let netdisk_name: String?
    let avatar_url: String?
    /// 0 普通用户 / 1 普通会员 / 2 超级会员
    let vip_type: Int?
    let uk: UInt64?
}

public struct BaiduPanQuotaResponse: Decodable {
    let errno: Int?
    let total: Int64?
    let used: Int64?
    let free: Int64?
}

// MARK: - 上传检查点

/// 上传断点续传检查点。
///
/// 中断后恢复流程：携带已存的 `uploadid` 重新 `precreate`（参数逐字一致），
/// **以云端返回的 `block_list` 为准**，不信任本地 `completedSlices`。
public struct BaiduPanUploadCheckpoint: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case precreated
        case uploading
        case merging
    }

    public let path: String
    public let uploadid: String
    public let size: Int64
    public let sliceSize: Int64
    public let rtype: Int
    public let blockMD5: [String]
    public var completedSlices: [Int]
    public var sliceMD5s: [String]
    public var state: State

    public init(
        path: String,
        uploadid: String,
        size: Int64,
        sliceSize: Int64,
        rtype: Int,
        blockMD5: [String],
        completedSlices: [Int],
        sliceMD5s: [String],
        state: State
    ) {
        self.path = path
        self.uploadid = uploadid
        self.size = size
        self.sliceSize = sliceSize
        self.rtype = rtype
        self.blockMD5 = blockMD5
        self.completedSlices = completedSlices
        self.sliceMD5s = sliceMD5s
        self.state = state
    }

    public var sliceCount: Int { blockMD5.count }

    public func sliceOffset(_ index: Int) -> Int64 {
        Int64(index) * sliceSize
    }

    public func sliceLength(_ index: Int) -> Int64 {
        guard index == blockMD5.count - 1 else { return sliceSize }
        return size - sliceOffset(index)
    }
}