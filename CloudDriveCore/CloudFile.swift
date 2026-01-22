//
//  CloudFile.swift
//  CloudDriveCore
//
//  云文件数据模型
//

import Foundation
import UniformTypeIdentifiers

/// 云文件模型
public struct CloudFile: Codable, Identifiable {
    public let id: String
    public let name: String
    public let parentId: String?
    public let isDirectory: Bool
    public let size: Int64
    public let contentType: String
    public let createdAt: Date
    public let modifiedAt: Date
    public let etag: String
    
    /// 本地缓存状态
    public var cacheStatus: CacheStatus
    
    /// 本地文件路径（如果已缓存）
    public var localPath: URL?
    
    /// 下载进度（0.0 - 1.0）
    public var downloadProgress: Double?
    
    public init(
        id: String,
        name: String,
        parentId: String?,
        isDirectory: Bool,
        size: Int64,
        contentType: String,
        createdAt: Date,
        modifiedAt: Date,
        etag: String,
        cacheStatus: CacheStatus = .notCached,
        localPath: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.isDirectory = isDirectory
        self.size = size
        self.contentType = contentType
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.etag = etag
        self.cacheStatus = cacheStatus
        self.localPath = localPath
    }
}

/// 缓存状态
public enum CacheStatus: String, Codable {
    case notCached      // 未缓存（仅占位符）
    case downloading    // 下载中
    case cached         // 已缓存
    case uploading      // 上传中
    case synced         // 已同步
    case conflict       // 冲突
}

extension CloudFile {
    /// 获取 UTType
    public var utType: UTType {
        if isDirectory {
            return .folder
        }
        return UTType(mimeType: contentType) ?? .data
    }
    
    /// 是否可以离线访问
    public var isAvailableOffline: Bool {
        return cacheStatus == .cached || cacheStatus == .synced
    }
    
    /// 格式化文件大小
    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}