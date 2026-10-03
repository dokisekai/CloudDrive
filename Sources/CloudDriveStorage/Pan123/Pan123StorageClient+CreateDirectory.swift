import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit
import UniformTypeIdentifiers

extension Pan123StorageClient {
    public func createDirectory(path: String) async throws {
        let canonical = normalizePath(path)
        if canonical == "/" {
            return
        }
        
        // 目标若已存在且是目录，直接成功
        if let existing = try? await resolveNode(for: canonical) {
            if existing.isDirectory { return }
            throw StorageError.serverError(statusCode: 412, message: "A file with the same name already exists")
        }
        
        let parentPath = (canonical as NSString).deletingLastPathComponent
        let dirName = (canonical as NSString).lastPathComponent
        try Self.validateFilename(dirName)
        
        // 确保父目录存在
        if parentPath != "/" {
            let parentExists = try await exists(path: parentPath)
            if !parentExists {
                try await createDirectory(path: parentPath)
            }
        }
        
        let parentNode = try await resolveNode(for: parentPath)
        guard parentNode.isDirectory else {
            throw StorageError.invalidOperation
        }
        
        let requestBody = Pan123MkdirRequest(name: dirName, parentID: parentNode.fileId)
        let mkdirData: Pan123MkdirData = try await apiClient.sendRequest(
            path: "upload/v1/file/mkdir",
            method: "POST",
            body: requestBody
        )
        
        let newDirNode = Pan123FileItem(
            fileId: mkdirData.dirID,
            filename: dirName,
            parentFileId: parentNode.fileId,
            type: 1,
            size: 0
        )
        cache.setNode(for: canonical, item: newDirNode)
        cache.invalidateChildren(for: parentNode.fileId)
    }
    
    /// 上传文件（默认覆盖）
}
