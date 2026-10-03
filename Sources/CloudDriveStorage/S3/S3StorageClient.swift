//
//  S3StorageClient.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  Amazon S3 及兼容对象存储协议客户端 (支持 AWS S3, MinIO, Cloudflare R2, Wasabi, 阿里云 OSS, 腾讯云 COS 等)
//

import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit
import UniformTypeIdentifiers

/// S3 协议存储客户端
public class S3StorageClient: StorageClient {
    public let config: S3StorageConfig
    let session: URLSession
    
    let isoDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return df
    }()
    
    let shortDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyyMMdd"
        return df
    }()
    
    public init(config: S3StorageConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }
}
