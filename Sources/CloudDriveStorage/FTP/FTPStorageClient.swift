//
//  FTPStorageClient.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  FTP / FTPS 协议存储客户端
//

import Foundation
import CloudDriveContracts
import CloudDriveSupport
import Network
import UniformTypeIdentifiers

/// FTP / FTPS 协议存储客户端
public class FTPStorageClient: StorageClient {
    public let config: FTPStorageConfig
    let session: URLSession
    
    public init(config: FTPStorageConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }
}
