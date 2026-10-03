//
//  RecycleBinVFSDelegate.swift
//  CloudDriveContracts
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  回收站与虚拟文件系统解耦契约
//

import Foundation

public protocol RecycleBinVFSDelegate: AnyObject, Sendable {
    var isEncrypted: Bool { get }
    func deleteFromLocalDatabaseOnly(itemId: String)
    func markPendingDelete(file: VirtualFileItem)
    func getItem(id: String) throws -> VirtualFileItem?
    func listDirectory(directoryId: String) throws -> [VirtualFileItem]
    func listLocalChildren(parentId: String) -> [VirtualFileItem]?
    func recordOfflineDirectory(id: String, name: String, parentId: String, remotePath: String)
    func recordOfflineFile(id: String, name: String, parentId: String, size: Int64, remotePath: String)
    func invalidateDirectoryCache(directoryId: String?)
    func resolveRestoredRemotePath(finalName: String, targetParentId: String, isDirectory: Bool) -> (remotePath: String, fileId: String)
    func scheduleRestoredUpload(fileId: String, fileName: String, parentId: String, localPath: String, remotePath: String, vaultId: String)
    func getRecycleBinDirectory() -> VirtualFileItem?
    func getOrCreateRecycleBinDirectory() async throws -> VirtualFileItem
    func moveToRecycleBin(item: VirtualFileItem) async throws -> VirtualFileItem
    func isRecycleBinDirectory(id: String) -> Bool
    func isItemInRecycleBin(item: VirtualFileItem) -> Bool
}
