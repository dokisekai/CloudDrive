//
//  FileProviderItem.swift
//  CloudDriveFileProvider
//
//  File Provider Item 实现 - iCloud 风格
//

import FileProvider
import UniformTypeIdentifiers
import CloudDriveCore
import AppKit
import os.log

class FileProviderItem: NSObject, NSFileProviderItem, NSFileProviderItemDecorating {
    
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let capabilities: NSFileProviderItemCapabilities
    let documentSize: NSNumber?
    let contentModificationDate: Date?
    let creationDate: Date?
    let itemVersion: NSFileProviderItemVersion
    
    // 缓存管理器和同步管理器
    private let cacheManager = CacheManager.shared
    private let syncManager = SyncManager.shared
    
    // 文件 ID（用于缓存查询）
    private var fileId: String {
        return itemIdentifier.rawValue
    }
    
    // MARK: - 上传状态（基于 SyncManager）
    
    var isUploaded: Bool {
        // 目录始终视为已上传
        if contentType == .folder {
            os_log("DEBUG: FileProviderItem isUploaded - Directory, returning true", log: .default, type: .debug)
            return true
        }
        
        // 检查同步状态
        if let metadata = syncManager.getMetadata(fileId: fileId) {
            os_log("DEBUG: FileProviderItem isUploaded - Metadata found, syncStatus: %@", log: .default, type: .debug, metadata.syncStatus.rawValue)
            switch metadata.syncStatus {
            case .synced, .cloudOnly:
                return true
            case .uploading, .pendingUpload, .localOnly:
                return false
            default:
                return true
            }
        }
        
        os_log("DEBUG: FileProviderItem isUploaded - No metadata, returning true", log: .default, type: .debug)
        return true
    }
    
    var isUploading: Bool {
        // 目录不需要上传
        if contentType == .folder {
            return false
        }
        
        // 检查同步状态
        if let metadata = syncManager.getMetadata(fileId: fileId) {
            return metadata.syncStatus == .uploading || metadata.syncStatus == .pendingUpload
        }
        
        return false
    }
    
    var uploadingError: Error? {
        if let metadata = syncManager.getMetadata(fileId: fileId),
           metadata.syncStatus == .error {
            return NSError(domain: "CloudDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: "上传失败"])
        }
        return nil
    }
    
    // MARK: - 下载状态（iCloud 风格，基于 SyncManager）
    
    /// 文件是否已下载到本地
    var isDownloaded: Bool {
        // 目录始终视为已下载
        if contentType == .folder {
            os_log("DEBUG: FileProviderItem isDownloaded - Directory, returning true", log: .default, type: .debug)
            return true
        }
        
        // 检查同步状态
        if let metadata = syncManager.getMetadata(fileId: fileId) {
            os_log("DEBUG: FileProviderItem isDownloaded - Metadata found, syncStatus: %@", log: .default, type: .debug, metadata.syncStatus.rawValue)
            switch metadata.syncStatus {
            case .synced, .localOnly, .uploading, .pendingUpload:
                return true
            case .cloudOnly, .downloading:
                return false
            default:
                let cached = cacheManager.isCached(fileId: fileId)
                os_log("DEBUG: FileProviderItem isDownloaded - Default case, checking cache: %@", log: .default, type: .debug, cached ? "true" : "false")
                return cached
            }
        }
        
        // 回退到缓存检查
        let cached = cacheManager.isCached(fileId: fileId)
        os_log("DEBUG: FileProviderItem isDownloaded - No metadata, checking cache: %@", log: .default, type: .debug, cached ? "true" : "false")
        return cached
    }
    
    /// 文件是否正在下载
    var isDownloading: Bool {
        // 目录不需要下载
        if contentType == .folder {
            os_log("DEBUG: FileProviderItem isDownloading - Directory, returning false", log: .default, type: .debug)
            return false
        }
        
        // 检查同步状态
        if let metadata = syncManager.getMetadata(fileId: fileId) {
            let isDownloading = metadata.syncStatus == .downloading
            os_log("DEBUG: FileProviderItem isDownloading - Metadata found, isDownloading: %@, syncStatus: %@", log: .default, type: .debug, isDownloading ? "true" : "false", metadata.syncStatus.rawValue)
            return isDownloading
        }
        
        os_log("DEBUG: FileProviderItem isDownloading - No metadata, returning false", log: .default, type: .debug)
        return false
    }
    
    /// 下载进度（0.0 到 1.0）
    var downloadProgress: Double {
        // 目录不需要下载进度
        if contentType == .folder {
            return 1.0
        }
        
        // 检查同步管理器中的进度信息
        if let metadata = syncManager.getMetadata(fileId: fileId) {
            if metadata.syncStatus == .downloading {
                // 使用元数据中存储的具体下载进度
                return metadata.downloadProgress
            } else if metadata.syncStatus == .synced || metadata.syncStatus == .localOnly {
                return 1.0
            } else if metadata.syncStatus == .cloudOnly {
                return 0.0
            }
        }
        
        // 默认情况下，如果文件已下载则返回1.0，否则返回0.0
        return isDownloaded ? 1.0 : 0.0
    }
    
    /// 下载错误
    var downloadingError: Error? {
        if let metadata = syncManager.getMetadata(fileId: fileId),
           metadata.syncStatus == .error {
            return NSError(domain: "CloudDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: "下载失败"])
        }
        return nil
    }
    
    /// 是否已下载最新版本
    var isMostRecentVersionDownloaded: Bool {
        let downloaded = isDownloaded
        os_log("DEBUG: FileProviderItem isMostRecentVersionDownloaded - Filename: %@, isDownloaded: %@", log: .default, type: .debug, filename, downloaded ? "true" : "false")
        return downloaded
    }
    
    // 必需的属性：文件权限
    var mostRecentEditorNameComponents: PersonNameComponents? {
        return nil
    }
    
    var contentTypeIdentifier: String {
        return contentType.identifier
    }
    
    // 可选的属性，提供默认值
    var tagData: Data? {
        return nil
    }
    
    var isShared: Bool {
        return false
    }
    
    var isDeleted: Bool {
        return false
    }
    
    var lastUsedDate: Date? {
        // 如果文件已缓存，返回最后访问时间
        if let metadata = cacheManager.getCacheMetadata(fileId: fileId) {
            return metadata.lastAccessedAt
        }
        return contentModificationDate
    }
    
    var thumbnailURL: URL? {
        return nil
    }
    
    init(identifier: NSFileProviderItemIdentifier,
         parentIdentifier: NSFileProviderItemIdentifier,
         filename: String,
         contentType: UTType,
         capabilities: NSFileProviderItemCapabilities,
         documentSize: Int64? = nil,
         contentModificationDate: Date? = nil,
         creationDate: Date? = nil) {
        
        self.itemIdentifier = identifier
        self.parentItemIdentifier = parentIdentifier
        self.filename = filename
        self.contentType = contentType
        self.capabilities = capabilities
        self.documentSize = documentSize.map { NSNumber(value: $0) }
        self.contentModificationDate = contentModificationDate
        self.creationDate = creationDate
        
        // 使用修改时间作为版本标识
        let versionString = contentModificationDate?.timeIntervalSince1970.description ?? "0"
        let versionData = versionString.data(using: .utf8) ?? Data()
        self.itemVersion = NSFileProviderItemVersion(contentVersion: versionData, metadataVersion: versionData)
        
        super.init()
    }
    
    convenience init(vfsItem: VirtualFileItem) {
        let identifier = NSFileProviderItemIdentifier(vfsItem.id)
        let parentIdentifier = vfsItem.parentId == "ROOT" ? .rootContainer : NSFileProviderItemIdentifier(vfsItem.parentId)
        
        var capabilities: NSFileProviderItemCapabilities = [.allowsReading, .allowsDeleting, .allowsRenaming]
        
        if vfsItem.isDirectory {
            capabilities.insert(.allowsAddingSubItems)
            capabilities.insert(.allowsContentEnumerating)
        } else {
            capabilities.insert(.allowsWriting)
        }
        
        let contentType: UTType = vfsItem.isDirectory ? .folder : .data
        
        self.init(
            identifier: identifier,
            parentIdentifier: parentIdentifier,
            filename: vfsItem.name,
            contentType: contentType,
            capabilities: capabilities,
            documentSize: vfsItem.isDirectory ? nil : vfsItem.size,
            contentModificationDate: vfsItem.modifiedAt,
            creationDate: vfsItem.modifiedAt
        )
    }
}

// MARK: - NSFileProviderItemDecorating
extension FileProviderItem {
    var decorations: [NSFileProviderItemDecorationIdentifier]? {
        // 对于未下载的文件，根据状态返回不同的装饰
        let downloaded = isDownloaded
        os_log("DEBUG: FileProviderItem decorations - Filename: %@, isDownloaded: %@", log: .default, type: .debug, filename, downloaded ? "true" : "false")
        
        if !downloaded {
            os_log("DEBUG: FileProviderItem decorations - File not downloaded, showing cloud decoration", log: .default, type: .debug)
            
            // 如果正在下载，我们可能需要显示进度
            if isDownloading {
                // 对于正在进行下载的文件，返回进度装饰
                return [
                    NSFileProviderItemDecorationIdentifier(rawValue: "com.apple.CloudDocuments.iCloudDrive"),
                    NSFileProviderItemDecorationIdentifier(rawValue: "com.clouddrive.download-progress")
                ]
            } else {
                // 对于未下载的文件，返回云朵图标装饰
                return [NSFileProviderItemDecorationIdentifier(rawValue: "com.apple.CloudDocuments.iCloudDrive")]
            }
        }
        
        os_log("DEBUG: FileProviderItem decorations - File is downloaded, returning nil", log: .default, type: .debug)
        return nil
    }
}