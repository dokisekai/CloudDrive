import Foundation
import FileProvider
import UniformTypeIdentifiers
import CloudDriveCore
import CloudDriveCache
@testable import CloudDriveFileProvider

private enum PresentationFailure: Error { case assertion(String) }

func runFileProviderPresentationRegressionTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fp-presentation-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = "/state-" + UUID().uuidString
    let sync = SyncManager(service: SyncService(metadataStore: SyncMetadataStore(metadataURL: root.appendingPathComponent("sync.db")), queue: OfflineSyncQueue(queueURL: root.appendingPathComponent("queue.db")), automaticallyProcessesQueue: false, notifiesFileProvider: false))
    let cache = CacheManager(service: CacheService(storage: CacheDiskStorage(cacheDirectory: root.appendingPathComponent("files")), metadataStore: CacheMetadataStore(metadataURL: root.appendingPathComponent("cache.db")), notifier: CacheNotificationService(vaultId: "presentation"), syncManager: sync, maximumCacheSize: 1024 * 1024))
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw PresentationFailure.assertion(message) }
    }
    func item() -> FileProviderItem {
        FileProviderItem(identifier: NSFileProviderItemIdentifier(id), parentIdentifier: .rootContainer, filename: String(repeating: "long-name", count: 30), contentType: .data, capabilities: [.allowsReading, .allowsWriting], documentSize: 4, cacheManager: cache, syncManager: sync)
    }
    var metadata = FileMetadata(fileId: id, name: "file", parentId: "/", isDirectory: false, syncStatus: .synced, etag: "\"v1\"", remoteETag: "\"v1\"")
    try sync.updateMetadataPersistent(metadata)
    let mounted = item()
    try require(mounted.isUploaded && !mounted.isDownloaded && !mounted.isMostRecentVersionDownloaded, "Mounted synced metadata without bytes must retain a download cloud")
    try cache.cacheFile(fileId: id, data: Data("old!".utf8))
    metadata.localPath = cache.localPath(for: id).path
    metadata.syncStatus = .cloudOnly
    try sync.updateMetadataPersistent(metadata)
    let available = item()
    try require(available.isDownloaded && available.isMostRecentVersionDownloaded && available.isUploaded, "Opening a confirmed matching cache must display local availability")
    try require(available.itemVersion.contentVersion == mounted.itemVersion.contentVersion && available.itemVersion.metadataVersion != mounted.itemVersion.metadataVersion, "Availability change must update metadata without requesting new content")
    metadata.remoteETag = "\"v2\""
    try sync.updateMetadataPersistent(metadata)
    let stale = item()
    try require(stale.isDownloaded && !stale.isMostRecentVersionDownloaded, "Old physical cache must not claim the newest remote version")
    try require(stale.itemVersion.contentVersion == Data("etag:\"v2\"".utf8), "Content version must track the latest listed remote revision")
    let stage = root.appendingPathComponent("accepted-stage")
    try Data("new!".utf8).write(to: stage)
    metadata.localPath = stage.path
    metadata.localModifiedAt = Date()
    metadata.syncStatus = .pendingUpload
    try sync.updateMetadataPersistent(metadata)
    let queued = item()
    try require(!queued.isUploaded && !queued.isUploading && queued.isDownloaded && queued.isMostRecentVersionDownloaded, "New copy waiting in the queue must be local and pending, not actively uploading")
    try require(queued.decorations?.contains(NSFileProviderItemDecorationIdentifier("com.clouddrive.decoration.pending")) == true, "Queued copy must expose the pending decoration")
    metadata.syncStatus = .uploading
    try sync.updateMetadataPersistent(metadata)
    let active = item()
    try require(active.isUploading && !queued.isUploading, "Each item must retain one immutable status snapshot")
    try require(active.itemVersion.contentVersion == queued.itemVersion.contentVersion && active.itemVersion.metadataVersion != queued.itemVersion.metadataVersion, "Transfer state must change metadata only")
    metadata.syncStatus = .synced
    metadata.etag = "\"v3\""
    metadata.remoteETag = "\"v3\""
    try sync.updateMetadataPersistent(metadata)
    let uploaded = item()
    metadata.syncStatus = .pendingMove
    try sync.updateMetadataPersistent(metadata)
    let moving = item()
    try require(moving.isUploaded && !moving.isUploading && moving.isMostRecentVersionDownloaded, "Moving an uploaded file must not masquerade as a content upload")
    try require(moving.itemVersion.contentVersion == uploaded.itemVersion.contentVersion, "A move must preserve the content version")
    metadata.syncStatus = .synced
    metadata.remoteETag = "\"" + String(repeating: "large-tag", count: 50) + "\""
    try sync.updateMetadataPersistent(metadata)
    let bounded = item()
    try require(bounded.itemVersion.contentVersion.count <= 128 && bounded.itemVersion.metadataVersion.count <= 128, "Long names, paths and ETags must respect File Provider version component limits")
    let folder = FileCloudState(metadata: FileMetadata(fileId: "/folder", name: "folder", parentId: "/", isDirectory: true, syncStatus: .pendingUpload), remoteETag: nil, hasLocalBytes: false, isDirectory: true, isExcluded: false)
    try require(folder.isDownloaded && !folder.isUploaded && !folder.isUploading, "Locally created directories still require confirmed remote creation")
    let missingExcluded = FileCloudState(metadata: nil, remoteETag: nil, hasLocalBytes: false, isDirectory: false, isExcluded: true)
    try require(!missingExcluded.isDownloaded, "Exclusion does not make missing bytes locally available")
    let failedRead = FileCloudState(metadata: FileMetadata(fileId: "/remote", name: "remote", parentId: "/", isDirectory: false, syncStatus: .error, remoteETag: "\"server-version\""), remoteETag: nil, hasLocalBytes: false, isDirectory: false, isExcluded: false)
    try require(failedRead.isUploaded && failedRead.hasDownloadError && !failedRead.hasUploadError, "A failed remote open must not turn into an upload failure")
    print("✅ Finder cloud snapshots: mount, cache open, stale revisions, new copies, moves and bounded versions passed")
}
