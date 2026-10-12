//
//  FileProviderItem.swift
//  CloudDriveFileProvider
//
//  File Provider Item Implementation - iCloud Style
//

import FileProvider
import UniformTypeIdentifiers
import CloudDriveCore
import CloudDriveSupport
import AppKit
import os.log
import CryptoKit

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
    
    private let fileId: String
    private let syncMetadata: FileMetadata?
    private let cloudState: FileCloudState
    private let excludedFromSync: Bool
    private let cachePolicy: CachePolicy
    private let snapshotLastUsedDate: Date?

    var isExcludedFromSync: Bool { excludedFromSync }
    var isUploaded: Bool { cloudState.isUploaded }
    var isUploading: Bool { cloudState.isUploading }
    var uploadingError: Error? { cloudState.hasUploadError ? NSFileProviderError(.serverUnreachable) : nil }
    var isDownloaded: Bool { cloudState.isDownloaded }
    var isDownloading: Bool { cloudState.isDownloading }
    var downloadProgress: Double { cloudState.downloadProgress }
    var downloadingError: Error? { cloudState.hasDownloadError ? NSFileProviderError(.serverUnreachable) : nil }
    var isMostRecentVersionDownloaded: Bool { cloudState.isMostRecentVersionDownloaded }

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
    
    var lastUsedDate: Date? { snapshotLastUsedDate ?? contentModificationDate }

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
        var effectiveCapabilities = capabilities
        if parentIdentifier != .trashContainer && identifier != .rootContainer && identifier != .trashContainer {
            effectiveCapabilities.insert(.allowsTrashing)
        }
        if contentType != .folder && parentIdentifier != .trashContainer {
            effectiveCapabilities.insert(.allowsEvicting)
        }
        if #available(macOS 13.0, *) {
            effectiveCapabilities.insert(.allowsExcludingFromSync)
        }
        self.capabilities = effectiveCapabilities
        self.documentSize = documentSize.map { NSNumber(value: $0) }
        self.contentModificationDate = contentModificationDate
        self.creationDate = creationDate
        self.isEncrypted = isEncrypted
        self.remoteETag = remoteETag
        self.cacheManager = cacheManager
        self.syncManager = syncManager
        
        let resolvedId = ItemAliasStore.shared.resolve(identifier.rawValue)
        self.fileId = resolvedId
        let metadata: FileMetadata?
        let metadataAvailable: Bool
        do {
            metadata = try syncManager.getMetadataPersistent(fileId: resolvedId)
            metadataAvailable = true
        } catch {
            metadata = nil
            metadataAvailable = false
        }
        self.syncMetadata = metadata
        let directory = metadata?.isDirectory == true || contentType.conforms(to: .directory)
        let vault = cacheManager.vaultId ?? ""
        let path = metadata?.remotePath ?? filename
        let excluded = filename.hasSuffix(".nosync") || metadata?.syncStatus == .localOnly || (!vault.isEmpty && (
            IgnoreRuleEngine.shared.shouldIgnore(path: path, name: filename, isDirectory: directory, vaultId: vault) ||
            IgnoreRuleEngine.shared.isUserExcluded(vaultId: vault, path: filename) ||
            IgnoreRuleEngine.shared.isUserExcluded(vaultId: vault, path: resolvedId) ||
            IgnoreRuleEngine.shared.isUserExcluded(vaultId: vault, path: path)))
        self.excludedFromSync = excluded
        self.cachePolicy = cacheManager.effectivePolicy(fileId: resolvedId)
        self.snapshotLastUsedDate = cacheManager.getCacheMetadata(fileId: resolvedId)?.lastAccessedAt
        let localBytes = cacheManager.isCached(fileId: resolvedId) || metadata?.localPath.map { FileManager.default.fileExists(atPath: $0) } == true
        let state = FileCloudState(metadata: metadata, remoteETag: metadata?.remoteETag ?? remoteETag, hasLocalBytes: localBytes, isDirectory: directory, isExcluded: excluded, metadataAvailable: metadataAvailable)
        self.cloudState = state
        let versionString = ContentRevision.token(metadata: metadata, remoteETag: remoteETag, modifiedAt: contentModificationDate, size: documentSize)
        let versionData = Data(versionString.utf8)
        // Status-only changes must refresh Finder without invalidating content.
        // Apple limits each version component to 128 bytes.
        let metadataVersionString = "v4:\(parentIdentifier.rawValue):\(filename):\(versionString):\(metadata?.syncStatus.rawValue ?? "remote"):\(state.isUploaded):\(state.isUploading):\(state.isDownloaded):\(state.isDownloading):\(state.isMostRecentVersionDownloaded):\(excluded):\(self.cachePolicy.rawValue):\(state.downloadProgress)"
        let metadataVersionData = Data(SHA256.hash(data: Data(metadataVersionString.utf8)))
        self.itemVersion = NSFileProviderItemVersion(contentVersion: versionData, metadataVersion: metadataVersionData)

        super.init()
    }
    
    convenience init(vfsItem: VirtualFileItem, isEncrypted: Bool = false, cacheManager: CacheManager = .shared, syncManager: SyncManager = .shared) {
        let identifier = NSFileProviderItemIdentifier(vfsItem.id)
        let parentIdentifier = (vfsItem.parentId == "ROOT" || vfsItem.parentId == "/" || vfsItem.parentId.isEmpty) ? .rootContainer : NSFileProviderItemIdentifier(vfsItem.parentId)
        
        var capabilities: NSFileProviderItemCapabilities = [.allowsReading, .allowsDeleting, .allowsTrashing, .allowsRenaming, .allowsReparenting]
        
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
        if cachePolicy == .pinned {
            return .downloadEagerlyAndKeepDownloaded
        }
        return contentType == .folder ? .inherited : .downloadLazily
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
        itemIdentifier != .rootContainer && !cloudState.isPending && !isUploading && !isDownloading && isUploaded && isMostRecentVersionDownloaded && !isExcludedFromSync
    }

    var decorations: [NSFileProviderItemDecorationIdentifier]? {
        guard itemIdentifier != .rootContainer else {
            return nil
        }
        
        var result: [NSFileProviderItemDecorationIdentifier] = []
        
        // 0. 排除同步状态：展示排除角标
        if isExcludedFromSync {
            result.append(NSFileProviderItemDecorationIdentifier("com.clouddrive.decoration.excluded"))
        }
        
        // 1. 同步错误与冲突状态：展示警告角标
        if let metadata = syncMetadata {
            if metadata.syncStatus == .error || metadata.syncStatus == .conflict {
                result.append(NSFileProviderItemDecorationIdentifier("com.clouddrive.decoration.warning"))
            } else if cloudState.isPending && !isUploading {
                // 等待上传排队中状态
                result.append(NSFileProviderItemDecorationIdentifier("com.clouddrive.decoration.pending"))
            }
        }
        
        // 2. 固定状态（用户显式设置“始终保留在此设备上”）
        if cachePolicy == .pinned {
            result.append(NSFileProviderItemDecorationIdentifier("com.clouddrive.decoration.pinned"))
        }
        
        // 参考原生 iCloud 体验规范：
        // 1. 锁图标（locked）：全部去除，避免视觉噪点（整个保险库为全量透明加密）。
        // 2. 已同步本地文件：无任何角标，呈现 macOS 原生纯净图标质感。
        // 3. 未下载到本地文件：由 isDownloaded == false 驱动 macOS 自动呈现 iCloud 云朵下载图标。
        // 4. 正在上传/下载文件：由 NSProgress 驱动呈现动态饼图进度圈。
        
        return result.isEmpty ? nil : result
    }
}