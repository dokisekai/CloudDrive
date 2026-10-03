import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit
import UniformTypeIdentifiers

extension Pan123StorageClient {
    public func copy(from sourcePath: String, to destinationPath: String) async throws {
        let srcCanonical = normalizePath(sourcePath)
        let destCanonical = normalizePath(destinationPath)
        guard srcCanonical != destCanonical else { return }
        
        let srcNode = try await resolveNode(for: srcCanonical)
        if srcNode.isDirectory {
            // 目录采用通用递归复制
            try await copyDirectoryRecursively(from: srcCanonical, to: destCanonical)
            return
        }
        
        let destParentPath = (destCanonical as NSString).deletingLastPathComponent
        let destName = (destCanonical as NSString).lastPathComponent
        let srcName = (srcCanonical as NSString).lastPathComponent
        
        if destName != srcName {
            try Self.validateFilename(destName)
        }
        
        if destParentPath != "/" {
            let destParentExists = try await exists(path: destParentPath)
            if !destParentExists {
                try await createDirectory(path: destParentPath)
            }
        }
        let destParentNode = try await resolveNode(for: destParentPath)
        guard destParentNode.isDirectory else {
            throw StorageError.invalidOperation
        }
        
        // 1. 调用原生复制接口
        let copyReq = Pan123CopyRequest(fileId: srcNode.fileId, targetDirId: destParentNode.fileId)
        let copyData: Pan123CopyData = try await apiClient.sendRequest(
            path: "api/v1/file/copy",
            method: "POST",
            body: copyReq
        )
        
        // 2. 若目标文件名不同，则重命名新复制的文件
        if destName != srcName {
            let renameReq = Pan123RenameRequest(fileId: copyData.targetFileId, fileName: destName)
            try await apiClient.sendEmptyResponseRequest(
                path: "api/v1/file/name",
                method: "PUT",
                body: renameReq
            )
        }
        
        cache.invalidateChildren(for: destParentNode.fileId)
        cache.invalidate(path: destCanonical)
    }
    
    /// 递归复制目录
    func copyDirectoryRecursively(from sourcePath: String, to destinationPath: String) async throws {
        try await createDirectory(path: destinationPath)
        let children = try await listDirectory(path: sourcePath)
        for child in children {
            let childSrc = child.path
            let childName = child.displayName
            let childDest = destinationPath == "/" ? "/\(childName)" : "\(destinationPath)/\(childName)"
            try await copy(from: childSrc, to: childDest)
        }
    }
    
    /// 测试连接有效性
}
