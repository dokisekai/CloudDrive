//
//  FileProviderItem.swift
//  CloudDriveFileProvider
//
//  File Provider Item Implementation - iCloud Style
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
    let isEncrypted: Bool
    
    // Cache manager and sync manager
    private let cacheManager: CacheManager
    private let syncManager: SyncManager
    private let remoteETag: String?
    
    // File ID (used for cache queries)
    private var fileId: String {
        return itemIdentifier.rawValue
    }
    
    // MARK: - Upload Status (based on SyncManager)
    
    var isUploaded: Bool {
        // Directories are always considered uploaded
        if contentType == .folder {
            os_log("DEBUG: FileProviderItem isUploaded - Directory, returning true", log: .default, type: .debug)
            return true
        }
        
        // Check sync status
        if let metadata = syncManager.getMetadata(fileId: fileId) {
            os_log("DEBUG: FileProviderItem isUploaded - Metadata found, syncStatus: %@", log: .default, type: .debug, metadata.syncStatus.rawValue)
            switch metadata.syncStatus {
            case .synced, .cloudOnly, .downloading, .partialDownload:
                return true
            case .uploading, .pendingUpload, .localOnly, .partialUpload, .pendingMove, .error, .conflict, .pendingDelete, .temporary, .locked, .verifying:
                return false
            @unknown default:
                return true
            }
        }
        
        os_log("DEBUG: FileProviderItem isUploaded - No metadata, returning true", log: .default, type: .debug)
        return true
    }
    
    var isUploading: Bool {
        // Directories do not require upload
        if contentType == .folder {
            return false
        }
        
        // Check sync status
        if let metadata = syncManager.getMetadata(fileId: fileId) {
            return metadata.syncStatus == .uploading
                || metadata.syncStatus == .pendingUpload
                || metadata.syncStatus == .partialUpload
        }
        
        return false
    }
    
    var uploadingError: Error? {
        if let metadata = syncManager.getMetadata(fileId: fileId),
           metadata.syncStatus == .error {
            return NSError(domain: "CloudDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: "Upload failed"])
        }
        return nil
    }
    
    // MARK: - Download Status (iCloud Style, based on SyncManager)
    
    private var isCacheStaleComparedToRemote: Bool {
        guard let cacheMeta = cacheManager.getCacheMetadata(fileId: fileId),
              let remoteDate = contentModificationDate else {
            return false
        }
        if let remoteETag, let baseline = syncManager.getMetadata(fileId: fileId)?.etag { return remoteETag != baseline }
        return remoteDate > cacheMeta.downloadedAt.addingTimeInterval(1.0)
    }
    
    /// Whether file is downloaded locally
    var isDownloaded: Bool {
        // Directories are always considered downloaded
        if contentType == .folder {
            os_log("DEBUG: FileProviderItem isDownloaded - Directory, returning true", log: .default, type: .debug)
            return true
        }
        
        let physicallyCached = cacheManager.isCached(fileId: fileId)
        guard physicallyCached else { return false }
        
        // If remote modification date is significantly newer than local cache download time, it is dirty and not treated as valid downloaded cache.
        if isCacheStaleComparedToRemote {
            return false
        }
        
        // Check sync status
        if let metadata = syncManager.getMetadata(fileId: fileId) {
            os_log("DEBUG: FileProviderItem isDownloaded - Metadata found, syncStatus: %@, physicallyCached: %@", log: .default, type: .debug, metadata.syncStatus.rawValue, physicallyCached ? "true" : "false")
            switch metadata.syncStatus {
            case .cloudOnly, .downloading, .partialDownload, .pendingDelete, .temporary:
                return false
            case .synced, .localOnly:
                return true
            case .uploading, .pendingUpload, .partialUpload:
                return true
            case .pendingMove, .error, .conflict, .locked, .verifying:
                return true
            @unknown default:
                return true
            }
        }
        
        // Fallback to physical cache check
        os_log("DEBUG: FileProviderItem isDownloaded - No metadata, checking cache: %@", log: .default, type: .debug, physicallyCached ? "true" : "false")
        return true
    }
    
    /// Whether file is currently downloading
    var isDownloading: Bool {
        // Directories do not require download
        if contentType == .folder {
            os_log("DEBUG: FileProviderItem isDownloading - Directory, returning false", log: .default, type: .debug)
            return false
        }
        
        // Check sync status
        if let metadata = syncManager.getMetadata(fileId: fileId) {
            let isDownloading = metadata.syncStatus == .downloading || metadata.syncStatus == .partialDownload
            os_log("DEBUG: FileProviderItem isDownloading - Metadata found, isDownloading: %@, syncStatus: %@", log: .default, type: .debug, isDownloading ? "true" : "false", metadata.syncStatus.rawValue)
            return isDownloading
        }
        
        os_log("DEBUG: FileProviderItem isDownloading - No metadata, returning false", log: .default, type: .debug)
        return false
    }
    
    /// Download progress (0.0 to 1.0)
    var downloadProgress: Double {
        // Directories do not require download progress
        if contentType == .folder {
            return 1.0
        }
        
        // Check progress info in SyncManager
        if let metadata = syncManager.getMetadata(fileId: fileId) {
            if metadata.syncStatus == .downloading || metadata.syncStatus == .partialDownload {
                // Use concrete download progress stored in metadata
                return metadata.downloadProgress
            } else if metadata.syncStatus == .synced || metadata.syncStatus == .localOnly {
                return isDownloaded ? 1.0 : 0.0
            } else if metadata.syncStatus == .cloudOnly {
                return 0.0
            }
        }
        
        // By default, return 1.0 if downloaded, else 0.0
        return isDownloaded ? 1.0 : 0.0
    }
    
    /// Download error
    var downloadingError: Error? {
        if let metadata = syncManager.getMetadata(fileId: fileId),
           metadata.syncStatus == .error {
            return NSError(domain: "CloudDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: "Download failed"])
        }
        return nil
    }
    
    /// Whether the most recent version is downloaded
    var isMostRecentVersionDownloaded: Bool {
        let downloaded = isDownloaded && !isCacheStaleComparedToRemote
        os_log("DEBUG: FileProviderItem isMostRecentVersionDownloaded - Filename: %@, isDownloaded: %@", log: .default, type: .debug, filename, downloaded ? "true" : "false")
        return downloaded
    }
    
    // Required properties: File capabilities
    var mostRecentEditorNameComponents: PersonNameComponents? {
        return nil
    }
    
    var contentTypeIdentifier: String {
        return contentType.identifier
    }
    
    // Optional properties with defaults
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
        // If cached, return last accessed time
        if let metadata = cacheManager.getCacheMetadata(fileId: fileId) {
            return metadata.lastAccessedAt
        }
        return contentModificationDate
    }
    
    var thumbnailURL: URL? {
        let size = CGSize(width: 256, height: 256)
        let vault = cacheManager.vaultId ?? "unconfigured"
        let thumbnailId = vault.utf8.map { String(format: "%02x", $0) }.joined() + ":" + fileId.utf8.map { String(format: "%02x", $0) }.joined()
        return ThumbnailManager.shared.cachedThumbnailURL(fileId: thumbnailId, size: size, timestamp: contentModificationDate.map { Int64($0.timeIntervalSince1970) })
    }
    
    init(identifier: NSFileProviderItemIdentifier,
         parentIdentifier: NSFileProviderItemIdentifier,
         filename: String,
         contentType: UTType,
         capabilities: NSFileProviderItemCapabilities,
         documentSize: Int64? = nil,
         contentModificationDate: Date? = nil,
         creationDate: Date? = nil,
         isEncrypted: Bool = false,
         remoteETag: String? = nil,
         cacheManager: CacheManager = .shared,
         syncManager: SyncManager = .shared) {
        
        self.itemIdentifier = identifier
        self.parentItemIdentifier = parentIdentifier
        self.filename = filename
        self.contentType = contentType
        self.capabilities = capabilities
        self.documentSize = documentSize.map { NSNumber(value: $0) }
        self.contentModificationDate = contentModificationDate
        self.creationDate = creationDate
        self.isEncrypted = isEncrypted
        self.remoteETag = remoteETag
        self.cacheManager = cacheManager
        self.syncManager = syncManager
        
        // Use modification date and document size as version identifier for robust cache invalidation
        let timeStr = contentModificationDate?.timeIntervalSince1970.description ?? "0"
        let sizeStr = documentSize?.description ?? "0"
        let versionString = remoteETag.map { "etag:\($0)" } ?? "\(timeStr)_\(sizeStr)"
        let versionData = versionString.data(using: .utf8) ?? Data()
        self.itemVersion = NSFileProviderItemVersion(contentVersion: versionData, metadataVersion: versionData)
        
        super.init()
    }
    
    convenience init(vfsItem: VirtualFileItem, isEncrypted: Bool = false, cacheManager: CacheManager = .shared, syncManager: SyncManager = .shared) {
        let identifier = NSFileProviderItemIdentifier(vfsItem.id)
        let parentIdentifier = (vfsItem.parentId == "ROOT" || vfsItem.parentId == "/" || vfsItem.parentId.isEmpty) ? .rootContainer : NSFileProviderItemIdentifier(vfsItem.parentId)
        
        var capabilities: NSFileProviderItemCapabilities = [.allowsReading, .allowsDeleting, .allowsRenaming, .allowsReparenting]
        
        if #available(macOS 13.0, *) {
            capabilities.insert(.allowsExcludingFromSync)
        }
        
        if vfsItem.isDirectory {
            capabilities.insert(.allowsAddingSubItems)
            capabilities.insert(.allowsContentEnumerating)
        } else {
            capabilities.insert(.allowsWriting)
            capabilities.insert(.allowsEvicting)
        }
        
        let ext = (vfsItem.name as NSString).pathExtension
        let contentType: UTType
        if vfsItem.isDirectory {
            if !ext.isEmpty, let packageType = UTType(filenameExtension: ext), packageType.conforms(to: .package) {
                contentType = packageType
            } else {
                contentType = .folder
            }
        } else {
            if !ext.isEmpty, let utType = UTType(filenameExtension: ext) {
                contentType = utType
            } else {
                contentType = .data
            }
        }
        
        self.init(
            identifier: identifier,
            parentIdentifier: parentIdentifier,
            filename: vfsItem.name,
            contentType: contentType,
            capabilities: capabilities,
            documentSize: vfsItem.isDirectory ? nil : vfsItem.size,
            contentModificationDate: vfsItem.modifiedAt,
            creationDate: vfsItem.modifiedAt,
            isEncrypted: isEncrypted,
            remoteETag: vfsItem.etag,
            cacheManager: cacheManager,
            syncManager: syncManager
        )
    }
    
    @available(macOS 13.0, *)
    var contentPolicy: NSFileProviderContentPolicy {
        if cacheManager.effectivePolicy(fileId: fileId) == .pinned || cacheManager.isCached(fileId: fileId) {
            return .downloadEagerlyAndKeepDownloaded
        }
        return contentType == .folder ? .inherited : .downloadLazilyAndEvictOnRemoteUpdate
    }
}

// MARK: - NSFileProviderItemDecorating
extension FileProviderItem {
    
    /// Indicates whether the item is encrypted (either from encrypted vault or ciphertext file format)
    var isEncryptedItem: Bool {
        guard itemIdentifier != .rootContainer else {
            return false
        }
        return isEncrypted
            || filename.hasSuffix(".c9r")
            || filename.hasSuffix(".c9s")
            || filename.hasSuffix(".cryptomator")
            || filename == "vault.cryptomator"
            || filename == "masterkey.cryptomator"
            || filename == "dirid.c9r"
    }
    
    /// Indicates whether the item is fully synced between local and cloud
    var isSynced: Bool {
        guard itemIdentifier != .rootContainer else {
            return false
        }
        
        // Items currently syncing are not marked as synced
        if isUploading || isDownloading {
            return false
        }
        
        // Check SyncManager status if available
        if let metadata = syncManager.getMetadata(fileId: fileId) {
            return metadata.syncStatus == .synced
        }
        
        // For directories without explicit sync metadata, consider synced
        if contentType == .folder {
            return true
        }
        
        // For regular files without metadata, consider synced if both cached and uploaded
        return isDownloaded && isUploaded
    }
    
    var decorations: [NSFileProviderItemDecorationIdentifier]? {
        guard itemIdentifier != .rootContainer else {
            return nil
        }
        
        var result: [NSFileProviderItemDecorationIdentifier] = []
        
        // 1. Syncing state (uploading / downloading in progress)
        if isUploading || isDownloading {
            result.append(NSFileProviderItemDecorationIdentifier("com.clouddrive.decoration.syncing"))
        } else if isSynced {
            // 2. Synced state (content is synced between local and remote)
            result.append(NSFileProviderItemDecorationIdentifier("com.clouddrive.decoration.synced"))
        }
        
        // 3. Encrypted state (encrypted vault file or Cryptomator ciphertext file)
        if isEncryptedItem {
            result.append(NSFileProviderItemDecorationIdentifier("com.clouddrive.decoration.locked"))
        }
        
        // 4. Pinned state (Always keep on this device badge)
        if cacheManager.effectivePolicy(fileId: fileId) == .pinned {
            result.append(NSFileProviderItemDecorationIdentifier("com.clouddrive.decoration.pinned"))
        }
        
        return result.isEmpty ? nil : result
    }
}