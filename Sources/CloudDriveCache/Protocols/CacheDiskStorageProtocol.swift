//
//  CacheDiskStorageProtocol.swift
//  CloudDriveCache
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  缓存物理磁盘存储协议
//

import Foundation
import CloudDriveContracts

/// 缓存物理磁盘存储协议 - 仅关注文件二进制 I/O 与磁盘路径
public protocol CacheDiskStorageProtocol: Sendable {
    var cacheDirectory: URL { get }
    
    /// 计算指定 fileId 的物理本地缓存路径
    func localPath(for fileId: String) -> URL
    
    /// 检查物理文件是否存在
    func exists(fileId: String) -> Bool
    
    /// 获取物理文件大小
    func fileSize(for fileId: String) -> Int64
    
    /// 写入二进制数据
    func write(data: Data, for fileId: String) throws
    
    /// 从源文件复制/克隆入缓存 (优先 APFS CoW)
    func cache(from sourceURL: URL, for fileId: String) throws -> Int64
    func cache(from sourceURL: URL, for fileId: String, onHashedContent: ((String) -> Void)?) throws -> Int64
    
    /// 读取缓存文件二进制
    func read(fileId: String) throws -> Data
    
    /// 删除单个缓存文件
    func remove(fileId: String) throws
    
    /// 移动/重命名单个缓存文件
    func move(from oldFileId: String, to newFileId: String) throws
    
    /// 移动/重命名目录缓存
    func moveDirectory(from oldDirId: String, to newDirId: String) throws
    
    /// 删除指定目录前缀下的所有物理缓存文件
    func removeDirectory(forDirectoryPrefix dirPrefix: String) throws
    
    /// 克隆物理缓存文件 (优先 APFS CoW)
    func clone(from sourceFileId: String, to destinationFileId: String) throws
    
    /// 清除所有物理缓存文件
    func clearAll() throws
    
    /// 列出磁盘上所有的物理文件相对路径集合
    func listAllDiskFiles() -> Set<String>
    
    /// 计算物理磁盘上实际缓存占用的总字节数
    func totalDiskSize() -> Int64
    
    /// 清理 CAS 去重池中的孤立 Blobs
    func pruneBlobs()
}

public extension CacheDiskStorageProtocol {
    func pruneBlobs() {}
    func cache(from sourceURL: URL, for fileId: String, onHashedContent: ((String) -> Void)?) throws -> Int64 {
        try cache(from: sourceURL, for: fileId)
    }
}
