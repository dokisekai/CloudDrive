//
//  BaiduPanSupport.swift
//  CloudDriveStorage
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  百度网盘支撑组件：会员档位 (Tier)、路径围栏 (Fence)、限流器 (RateLimiter)、错误码映射 (ErrorMapping)
//

import Foundation
import CloudDriveContracts

// MARK: - 会员档位 (Tier)

/// 用户 VIP 档位，决定单文件上传上限与分片大小
public enum BaiduPanTier: Int, Sendable, Codable, Equatable {
    case standard = 0
    case vip = 1
    case svip = 2

    public init(vipType: Int) {
        self = BaiduPanTier(rawValue: vipType) ?? .standard
    }

    /// 单个分片上传大小（普通 4MB，会员 16MB，超级会员 32MB）
    public var sliceSize: Int64 {
        switch self {
        case .standard: return 4 * 1024 * 1024
        case .vip:      return 16 * 1024 * 1024
        case .svip:     return 32 * 1024 * 1024
        }
    }

    /// 单文件上传大小硬上限（普通 4GB，会员 10GB，超级会员 20GB）
    public var maxFileSize: Int64 {
        switch self {
        case .standard: return 4 * 1024 * 1024 * 1024
        case .vip:      return 10 * 1024 * 1024 * 1024
        case .svip:     return 20 * 1024 * 1024 * 1024
        }
    }

    public var displayName: String {
        switch self {
        case .standard: return "普通用户"
        case .vip:      return "普通会员"
        case .svip:     return "超级会员 (SVIP)"
        }
    }
}

// MARK: - 路径围栏 (Fence)

/// 百度网盘第三方应用目录围栏 `/apps/{appFolderName}`
public struct BaiduPanPathFence: Sendable {
    public let appFolderName: String

    public init(appFolderName: String) {
        let clean = appFolderName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.appFolderName = clean.isEmpty ? "CloudDrive" : clean
    }

    public var prefix: String {
        "/apps/\(appFolderName)"
    }

    /// 将逻辑路径（如 `/vault/data.c9r`）转换为百度网盘远程物理路径（幂等安全，防重复前缀）
    public func resolve(_ logicalPath: String) throws -> String {
        let trimmed = logicalPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty {
            return prefix
        }
        let cleanPrefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed == cleanPrefix {
            return prefix
        }
        if trimmed.hasPrefix(cleanPrefix + "/") {
            return "/" + trimmed
        }
        return "\(prefix)/\(trimmed)"
    }

    /// 将百度网盘物理路径转换为逻辑路径（安全清理所有围栏前缀）
    public func toLogicalPath(_ remotePath: String) -> String {
        var current = remotePath
        let cleanPrefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        while true {
            let trimmed = current.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if trimmed == cleanPrefix || trimmed.isEmpty {
                return "/"
            }
            if trimmed.hasPrefix(cleanPrefix + "/") {
                let sub = String(trimmed.dropFirst(cleanPrefix.count))
                current = sub.hasPrefix("/") ? sub : "/" + sub
            } else {
                return current.hasPrefix("/") ? current : "/" + current
            }
        }
    }

    /// 校验远程路径是否在围栏内
    public func assertWithinFence(_ remotePath: String) throws {
        let trimmed = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanPrefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard trimmed == cleanPrefix || trimmed.hasPrefix(cleanPrefix + "/") else {
            throw StorageError.permissionDenied
        }
    }

    /// 文件名有效性检测（禁止包含 `/\:*?"<>|` 等非法字符）
    public static func isValidFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.rangeOfCharacter(from: illegal) == nil
    }
}

// MARK: - 限流器 (RateLimiter)

/// 客户端请求频率保护器，防止触发 31034 频控
public final class BaiduPanRateLimiter: @unchecked Sendable {
    private let maxRequestsPerMinute: Int
    private let maxRequestsPerDay: Int
    private var timestamps: [Date] = []
    private let lock = NSLock()

    public init(maxRequestsPerMinute: Int = 600, maxRequestsPerDay: Int = 50_000) {
        self.maxRequestsPerMinute = maxRequestsPerMinute
        self.maxRequestsPerDay = maxRequestsPerDay
    }

    public func consume() throws {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        timestamps.removeAll { now.timeIntervalSince($0) > 60 }
        if timestamps.count >= maxRequestsPerMinute {
            throw StorageError.serverError(statusCode: 429, message: "BaiduPan rate limit exceeded")
        }
        timestamps.append(now)
    }
}

// MARK: - 错误码映射 (ErrorMapping)

public enum BaiduPanErrorMapping {
    public static let dlinkExpiredCode = 31360

    /// 是否为 Token 过期或鉴权失效，需要自动刷新 Token
    public static func shouldRefreshToken(errno: Int) -> Bool {
        switch errno {
        case -6:    // 身份验证失败 (Invalid Bduss / access_token 失效)
            return true
        case 20016: // access_token 已过期
            return true
        case 20017: // access_token 无效
            return true
        case 31045: // access_token 验证未通过
            return true
        default:
            return false
        }
    }

    /// 将官方 errno 映射为体系统一的 StorageError
    public static func map(errno: Int, errmsg: String?) -> StorageError {
        let msg = errmsg ?? "errno: \(errno)"
        switch errno {
        case 0:
            return .invalidOperation
        case -6, 20016, 20017, 31045:
            return .authenticationFailed
        case -9, 31066:
            return .notFound
        case -8, 31061:
            return .fileSystemError("文件或目录已存在 (\(msg))")
        case -7, 20020, 31064, 31024:
            return .permissionDenied
        case -10:
            return .fileSystemError("云端空间不足 (\(msg))")
        case 2, 31023:
            return .invalidOperation
        case 20012, 31034:
            return .serverError(statusCode: 429, message: "触发接口频控限制: \(msg)")
        case 31326:
            return .permissionDenied
        case 31360:
            return .serverError(statusCode: 410, message: "下载链接已过期 (dlink expired)")
        case 31362:
            return .serverError(statusCode: 400, message: "下载签名错误 (signature error)")
        case 31190, 31355, 31363:
            return .invalidOperation
        case 31364:
            return .notSupported("超出分片大小限制: \(msg)")
        case 31365:
            return .notSupported("单文件总大小超限: \(msg)")
        case 111:
            return .serverError(statusCode: 503, message: "有其他异步任务正在执行，请稍后重试")
        default:
            return .serverError(statusCode: 500, message: "百度网盘错误 [\(errno)]: \(msg)")
        }
    }
}
