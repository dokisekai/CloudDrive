import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit
import UniformTypeIdentifiers

extension Pan123StorageClient {
    // MARK: - StorageClient Implementation
    
    /// 检查路径是否存在
    public func exists(path: String) async throws -> Bool {
        let canonical = normalizePath(path)
        if canonical == "/" {
            return true
        }
        do {
            _ = try await resolveNode(for: canonical)
            return true
        } catch StorageError.notFound {
            return false
        }
    }
    
    /// 列出目录内容
    public func listDirectory(path: String) async throws -> [StorageResource] {
        let canonical = normalizePath(path)
        let dirNode = try await resolveNode(for: canonical)
        guard dirNode.isDirectory else {
            throw StorageError.invalidOperation
        }
        
        let items = try await fetchFileList(parentFileId: dirNode.fileId)
        cache.setChildren(for: dirNode.fileId, items: items)
        
        return items.map { item in
            let itemPath = canonical == "/" ? "/\(item.filename)" : "\(canonical)/\(item.filename)"
            cache.setNode(for: itemPath, item: item)
            
            let cDate = item.createAt.flatMap { self.dateFormatter.date(from: $0) }
            let mDate = item.updateAt.flatMap { self.dateFormatter.date(from: $0) }
            
            var cType: String? = nil
            if !item.isDirectory {
                let ext = (item.filename as NSString).pathExtension
                if !ext.isEmpty, let uti = UTType(filenameExtension: ext) {
                    cType = uti.preferredMIMEType
                }
            }
            
            return StorageResource(
                path: itemPath,
                displayName: item.filename,
                isDirectory: item.isDirectory,
                contentLength: item.size,
                contentType: cType,
                creationDate: cDate,
                lastModified: mDate,
                etag: item.etag
            )
        }
    }
    
    /// 创建目录（递归创建缺失的父目录，包含非法字符与长度校验）
}
