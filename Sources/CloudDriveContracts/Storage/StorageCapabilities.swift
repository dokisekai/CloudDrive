//
//  StorageCapabilities.swift
//  CloudDriveContracts
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  统一存储传输层能力抽象模型 - 供 VFS、同步队列与传输管理器自动判断存储源特性
//

import Foundation

/// 存储客户端特性与能力集
public struct StorageCapabilities: Sendable, Codable, Equatable {
    /// 是否支持断点续传下载（通过 HTTP Range 或原生分块读取）
    public let supportsResumableDownload: Bool
    
    /// 是否支持断点续传上传（通过分块切片或持久化断点记录）
    public let supportsResumableUpload: Bool
    
    /// 是否支持秒传（基于文件哈希的比对秒传）
    public let supportsFastUpload: Bool
    
    /// 是否支持服务端原生重命名与移动
    public let supportsServerSideMove: Bool
    
    /// 是否支持服务端原生复制
    public let supportsServerSideCopy: Bool
    
    /// 单文件最大上传限制（字节，如 123云盘限制 10GB；nil 表示无限制）
    public let maxUploadFileSize: Int64?
    
    /// 推荐的分片/分块大小（字节，如 123云盘推荐 16MB；nil 表示无需切片）
    public let preferredSliceSize: Int64?
    
    public init(
        supportsResumableDownload: Bool = false,
        supportsResumableUpload: Bool = false,
        supportsFastUpload: Bool = false,
        supportsServerSideMove: Bool = true,
        supportsServerSideCopy: Bool = false,
        maxUploadFileSize: Int64? = nil,
        preferredSliceSize: Int64? = nil
    ) {
        self.supportsResumableDownload = supportsResumableDownload
        self.supportsResumableUpload = supportsResumableUpload
        self.supportsFastUpload = supportsFastUpload
        self.supportsServerSideMove = supportsServerSideMove
        self.supportsServerSideCopy = supportsServerSideCopy
        self.maxUploadFileSize = maxUploadFileSize
        self.preferredSliceSize = preferredSliceSize
    }
}
