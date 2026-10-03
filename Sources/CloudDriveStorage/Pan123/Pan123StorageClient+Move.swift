import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit
import UniformTypeIdentifiers

extension Pan123StorageClient {
    public func move(from sourcePath: String, to destinationPath: String) async throws {
        try await move(from: sourcePath, to: destinationPath, expectedETag: nil)
    }
    
    /// 移动 / 重命名（带源版本约束，校验目标命名与分批支持）
    public func move(from sourcePath: String, to destinationPath: String, expectedETag: String?) async throws {
        let srcCanonical = normalizePath(sourcePath)
        let destCanonical = normalizePath(destinationPath)
        guard srcCanonical != destCanonical else { return }
        
        let srcNode = try await resolveNode(for: srcCanonical)
        if let expected = expectedETag, let remoteETag = srcNode.etag, !remoteETag.isEmpty, remoteETag != expected {
            throw StorageError.serverError(statusCode: 412, message: "Precondition Failed")
        }
        
        let destParentPath = (destCanonical as NSString).deletingLastPathComponent
        let destName = (destCanonical as NSString).lastPathComponent
        let srcParentPath = (srcCanonical as NSString).deletingLastPathComponent
        let srcName = (srcCanonical as NSString).lastPathComponent
        
        if destName != srcName {
            try Self.validateFilename(destName)
        }
        
        // 确保目标父目录存在
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
        
        // 跨目录移动 (利用 batchMove 处理分批)
        if srcParentPath != destParentPath {
            try await apiClient.batchMove(fileIDs: [srcNode.fileId], toParentFileID: destParentNode.fileId)
        }
        
        // 重命名
        if srcName != destName {
            let renameReq = Pan123RenameRequest(fileId: srcNode.fileId, fileName: destName)
            try await apiClient.sendEmptyResponseRequest(
                path: "api/v1/file/name",
                method: "PUT",
                body: renameReq
            )
        }
        
        cache.invalidate(path: srcCanonical)
        cache.invalidate(path: destCanonical)
        let srcParentNode = try? await resolveNode(for: srcParentPath)
        if let spId = srcParentNode?.fileId {
            cache.invalidateChildren(for: spId)
        }
        cache.invalidateChildren(for: destParentNode.fileId)
    }
    
    /// 删除文件或目录（移入回收站）
}
