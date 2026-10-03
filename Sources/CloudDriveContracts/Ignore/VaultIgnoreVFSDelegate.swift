//
//  VaultIgnoreVFSDelegate.swift
//  CloudDriveContracts
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  忽略规则文件同步代理契约
//

import Foundation

public protocol VaultIgnoreVFSDelegate: AnyObject, Sendable {
    func listDirectoryFromWebDAVAsync(directoryId: String) async throws -> [VirtualFileItem]
    func downloadFile(fileId: String, to destinationURL: URL, progress: ((Double) -> Void)?) async throws
    func uploadFile(localURL: URL, name: String, parentId: String) async throws -> VirtualFileItem
}
