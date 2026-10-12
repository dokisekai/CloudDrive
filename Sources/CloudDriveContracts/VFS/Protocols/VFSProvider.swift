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
    var storageCapabilities: StorageCapabilities { get }
    
    func getItem(id: String) throws -> VirtualFileItem?
    func listDirectory(directoryId: String, forceRefresh: Bool) async throws -> [VirtualFileItem]
    func createDirectory(name: String, parentId: String) async throws -> VirtualFileItem
    func uploadFile(localURL: URL, name: String, parentId: String) async throws -> VirtualFileItem
    func uploadFile(localURL: URL, name: String, parentId: String, expectedETag: String?, progress: ((Double) -> Void)?) async throws -> VirtualFileItem
    func downloadFile(fileId: String, to destinationURL: URL, progress: ((Double) -> Void)?) async throws
    func downloadFile(fileId: String, to destinationURL: URL, expectedETag: String?, progress: ((Double) -> Void)?) async throws -> String?
    func delete(itemId: String) async throws
    func moveItem(itemId: String, newParentId: String, newName: String?) async throws -> VirtualFileItem
    func copyItem(itemId: String, newParentId: String, newName: String?) async throws -> VirtualFileItem
    func copyItem(itemId: String, newParentId: String, newName: String?, cachedContentOverride: String, expectedSourceETag: String) async throws -> VirtualFileItem
    func modifyFile(fileId: String, newContent: URL) async throws -> VirtualFileItem
    func invalidateDirectoryCache(directoryId: String?)
    func readRange(fileId: String, range: ClosedRange<Int64>) async throws -> Data
    func readRange(fileId: String, range: ClosedRange<Int64>, expectedETag: String?) async throws -> Data
}

public extension VFSProvider {
    func copyItem(itemId: String, newParentId: String, newName: String?, cachedContentOverride: String, expectedSourceETag: String) async throws -> VirtualFileItem {
        throw StorageError.notSupported("Verified cached-content copies are unavailable")
    }

    var storageCapabilities: StorageCapabilities {
        StorageCapabilities()
    }
    
    func uploadFile(localURL: URL, name: String, parentId: String, expectedETag: String?, progress: ((Double) -> Void)?) async throws -> VirtualFileItem {
        try await uploadFile(localURL: localURL, name: name, parentId: parentId)
    }
    
    func downloadFile(fileId: String, to destinationURL: URL, expectedETag: String?, progress: ((Double) -> Void)?) async throws -> String? {
        guard expectedETag == nil else { throw StorageError.notSupported("Revision-bound VFS downloads are unavailable") }
        try await downloadFile(fileId: fileId, to: destinationURL, progress: progress)
        return nil
    }

    func readRange(fileId: String, range: ClosedRange<Int64>, expectedETag: String?) async throws -> Data {
        guard expectedETag == nil else { throw StorageError.notSupported("Revision-bound VFS range reads are unavailable") }
        return try await readRange(fileId: fileId, range: range)
    }

    func readRange(fileId: String, range: ClosedRange<Int64>) async throws -> Data {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("vfs_range_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try await downloadFile(fileId: fileId, to: tempURL, progress: nil)
        guard let handle = try? FileHandle(forReadingFrom: tempURL) else {
            return Data()
        }
        defer { try? handle.close() }
        let start = max(0, UInt64(range.lowerBound))
        try handle.seek(toOffset: start)
        let count = Int(max(0, range.upperBound - range.lowerBound + 1))
        return (try handle.read(upToCount: count)) ?? Data()
    }
}
