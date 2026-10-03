//
//  VFSProvider.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  虚拟文件系统驱动协议 (抽象驱动层)
//

import Foundation

/// 虚拟文件系统抽象驱动协议
public protocol VFSProvider: AnyObject, Sendable {
    var vaultId: String { get }
    var isEncrypted: Bool { get }
    var rootId: String { get }
    
    func getItem(id: String) throws -> VirtualFileItem?
    func listDirectory(directoryId: String, forceRefresh: Bool) async throws -> [VirtualFileItem]
    func createDirectory(name: String, parentId: String) async throws -> VirtualFileItem
    func uploadFile(localURL: URL, name: String, parentId: String) async throws -> VirtualFileItem
    func downloadFile(fileId: String, to destinationURL: URL, progress: ((Double) -> Void)?) async throws
    func delete(itemId: String) async throws
    func moveItem(itemId: String, newParentId: String, newName: String?) async throws -> VirtualFileItem
    func copyItem(itemId: String, newParentId: String, newName: String?) async throws -> VirtualFileItem
    func modifyFile(fileId: String, newContent: URL) async throws -> VirtualFileItem
    func invalidateDirectoryCache(directoryId: String?)
}
