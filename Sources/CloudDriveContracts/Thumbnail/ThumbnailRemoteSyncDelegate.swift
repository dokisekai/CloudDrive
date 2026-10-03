//
//  ThumbnailRemoteSyncDelegate.swift
//  CloudDriveContracts
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  缩略图云端清单包双向同步契约协议
//

import Foundation

public protocol ThumbnailRemoteSyncDelegate: AnyObject, Sendable {
    func listDirectoryForThumbnails(directoryId: String) async throws -> [VirtualFileItem]
    func downloadThumbnailFile(fileId: String, to destinationURL: URL) async throws
    func uploadThumbnailFile(localURL: URL, name: String, parentId: String) async throws
}
