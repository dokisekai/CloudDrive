import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit
import UniformTypeIdentifiers

extension Pan123StorageClient {
    public func delete(path: String) async throws {
        try await delete(path: path, expectedETag: nil)
    }
    
    /// 删除文件或目录（带版本约束，利用 batchTrash 处理分批）
    public func delete(path: String, expectedETag: String?) async throws {
        let canonical = normalizePath(path)
        guard canonical != "/" else {
            throw StorageError.permissionDenied
        }
        
        let node = try await resolveNode(for: canonical)
        if let expected = expectedETag, let remoteETag = node.etag, !remoteETag.isEmpty, remoteETag != expected {
            throw StorageError.serverError(statusCode: 412, message: "Precondition Failed")
        }
        
        try await apiClient.batchTrash(fileIDs: [node.fileId])
        
        cache.invalidate(path: canonical)
        let parentPath = (canonical as NSString).deletingLastPathComponent
        if let parentNode = try? await resolveNode(for: parentPath) {
            cache.invalidateChildren(for: parentNode.fileId)
        }
    }
    
    /// 复制文件（支持 123云盘原生单文件复制）
}
