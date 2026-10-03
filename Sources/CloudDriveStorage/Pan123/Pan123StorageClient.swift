//
//  Pan123StorageClient.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  123云盘开放平台存储客户端实现 - 遵循统一 StorageClient 协议
//  参考文档: https://123yunpan.yuque.com/org-wiki-123yunpan-muaork/cr6ced
//

import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit
import UniformTypeIdentifiers

/// 123云盘路径解析与节点缓存管理
public class Pan123StorageClient: StorageClient {
    public let config: Pan123StorageConfig
    public let apiClient: Pan123APIClient
    let session: URLSession
    let cache = Pan123PathCache()
    
    /// 123云盘开放平台单文件最大上传限制：10GB (10 * 1024 * 1024 * 1024 bytes)
    public static let maxUploadFileSize: Int64 = 10 * 1024 * 1024 * 1024
    
    /// 123云盘文件名禁止包含的非法字符
    public static let illegalFilenameCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
    
    let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone.current
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df
    }()
    
    public init(
        config: Pan123StorageConfig,
        baseURL: URL = URL(string: "https://open-api.123pan.com")!,
        session: URLSession = .shared,
        databaseStore: Pan123DatabaseStore? = nil,
        baseRetryDelay: TimeInterval = 0.5,
        maxRateLimitRetries: Int = 3
    ) {
        self.config = config
        self.session = session
        self.apiClient = Pan123APIClient(
            config: config,
            baseURL: baseURL,
            session: session,
            databaseStore: databaseStore,
            baseRetryDelay: baseRetryDelay,
            maxRateLimitRetries: maxRateLimitRetries
        )
    }
}
