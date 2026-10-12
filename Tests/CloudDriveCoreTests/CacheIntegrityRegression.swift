import Foundation
import SQLite3
import CloudDriveCore
import CloudDriveCache

private enum CacheIntegrityFailure: Error { case assertion(String) }

func runCacheIntegrityRegressionTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cache-integrity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func require(_ value: Bool, _ message: String) throws {
        if !value { throw CacheIntegrityFailure.assertion(message) }
    }
    let disk = CacheDiskStorage(cacheDirectory: root.appendingPathComponent("Files"))
    let content = Data("immutable original".utf8)
    let source = root.appendingPathComponent("source")
    try content.write(to: source)
    _ = try disk.cache(from: source, for: "/first")
    let hash = CacheDiskStorage.computeSHA256(of: content)
    let blob = disk.blobsDirectory.appendingPathComponent(String(hash.prefix(2))).appendingPathComponent(hash)
    try Data("CORRUPTED CONTENT!".utf8).write(to: blob, options: .atomic)
    _ = try disk.cache(from: source, for: "/second")
    try require(try disk.read(fileId: "/second") == content, "A damaged CAS pool entry must not replace correct source bytes")
    try require(try CacheDiskStorage.computeSHA256(of: blob) == hash, "CAS content must match its hash after repair")
    try disk.write(data: Data("destination".utf8), for: "/destination")
    do {
        try disk.move(from: "/first", to: "/destination")
        throw CacheIntegrityFailure.assertion("Conflicting cache move must fail")
    } catch let error as CocoaError where error.code == .fileWriteFileExists { }
    try require(try disk.read(fileId: "/destination") == Data("destination".utf8), "Failed cache move must retain existing destination")
    try require(try disk.read(fileId: "/first") == content, "Failed cache move must retain source")
    let metadata = CacheMetadataStore(metadataURL: root.appendingPathComponent("metadata.db"))
    for id in ["/percent%/child", "/percentX/child", "/under_score/child", "/underXscore/child"] {
        metadata.set(CacheMetadata(fileId: id, size: 1, downloadedAt: Date(), lastAccessedAt: Date(), policy: .pinned))
    }
    _ = metadata.removePrefix("/percent%")
    _ = metadata.removePrefix("/under_score")
    try require(metadata.get(for: "/percentX/child")?.policy == .pinned && metadata.get(for: "/underXscore/child")?.policy == .pinned, "Cache directory deletion must use literal path prefixes")
    let legacyURL = root.appendingPathComponent("legacy.db")
    let legacy = SQLiteConnection(dbPath: legacyURL)
    try legacy.execute(sql: "CREATE TABLE cache_metadata(file_id TEXT PRIMARY KEY, size INTEGER, downloaded_at REAL, last_accessed_at REAL, policy TEXT); INSERT INTO cache_metadata VALUES('/pinned', 9, 1, 2, 'pinned');")
    legacy.close()
    let migrated = CacheMetadataStore(metadataURL: legacyURL)
    try require(migrated.isHealthy && migrated.get(for: "pinned")?.policy == .pinned, "Legacy cache migration must preserve pin intent")
    let unknownURL = root.appendingPathComponent("unknown.db")
    let unknown = SQLiteConnection(dbPath: unknownURL)
    try unknown.execute(sql: "CREATE TABLE cache_metadata(sentinel TEXT); INSERT INTO cache_metadata VALUES('retain-me');")
    let damaged = CacheMetadataStore(metadataURL: unknownURL)
    try require(!damaged.isHealthy, "An unknown cache schema must disable eviction")
    let preserved = try SQLiteStatement(db: unknown.getHandle(), sql: "SELECT sentinel FROM cache_metadata;")
    try require(preserved.step() == SQLITE_ROW && preserved.columnText(at: 0) == "retain-me", "Unknown metadata must not be silently dropped")
    let corruptSyncURL = root.appendingPathComponent("corrupt-sync.db")
    try Data("broken database".utf8).write(to: corruptSyncURL)
    let sync = SyncManager(service: SyncService(metadataStore: SyncMetadataStore(metadataURL: corruptSyncURL), queue: OfflineSyncQueue(queueURL: root.appendingPathComponent("queue.db")), automaticallyProcessesQueue: false, notifiesFileProvider: false))
    let service = CacheService(storage: disk, metadataStore: metadata, notifier: CacheNotificationService(vaultId: "integrity"), syncManager: sync, maximumCacheSize: 100000)
    do {
        try service.evictFile(fileId: "/first")
        throw CacheIntegrityFailure.assertion("Unreadable sync state must prevent eviction")
    } catch let error as CocoaError where error.code == .fileWriteNoPermission { }
    try require(disk.exists(fileId: "/first"), "Cache bytes must survive unreadable protection state")
    let healthySync = SyncManager(service: SyncService(metadataStore: SyncMetadataStore(metadataURL: root.appendingPathComponent("healthy-sync.db")), queue: OfflineSyncQueue(queueURL: root.appendingPathComponent("healthy-queue.db")), automaticallyProcessesQueue: false, notifiesFileProvider: false))
    let protectedService = CacheService(storage: disk, metadataStore: metadata, notifier: CacheNotificationService(vaultId: "protected"), syncManager: healthySync, maximumCacheSize: 100000)
    for (id, status) in [("/tree/clean", SyncStatus.synced), ("/tree/dirty", .pendingUpload), ("/tree/pinned", .synced), ("/tree-sibling/file", .synced)] {
        try disk.write(data: content, for: id)
        metadata.set(CacheMetadata(fileId: id, size: Int64(content.count), downloadedAt: Date(), lastAccessedAt: Date(), policy: id == "/tree/pinned" ? .pinned : .automatic))
        try healthySync.updateMetadataPersistent(FileMetadata(fileId: id, name: "file", parentId: "/tree", isDirectory: false, syncStatus: status, localPath: disk.localPath(for: id).path, size: Int64(content.count), etag: "\"confirmed\""))
    }
    protectedService.removeDirectoryCache(forDirectoryPrefix: "/tree")
    try require(!disk.exists(fileId: "/tree/clean"), "Clean directory cache should be removed")
    try require(disk.exists(fileId: "/tree/dirty") && disk.exists(fileId: "/tree/pinned") && disk.exists(fileId: "/tree-sibling/file"), "Directory cleanup must retain dirty, pinned and sibling content")
    try require(try healthySync.getMetadataPersistent(fileId: "/tree/clean")?.syncStatus == .cloudOnly, "Eviction must persist clean state under the commit lock")
    try require(try healthySync.getMetadataPersistent(fileId: "/tree/dirty")?.syncStatus == .pendingUpload, "Eviction must never clear dirty state")
    do {
        try protectedService.removeCachedFile(fileId: "/tree/dirty")
        throw CacheIntegrityFailure.assertion("Direct cache removal must respect dirty protection")
    } catch let error as CocoaError where error.code == .fileWriteNoPermission { }
    for id in ["/move-dir/child", "/taken/child"] {
        try disk.write(data: content, for: id)
        metadata.set(CacheMetadata(fileId: id, size: Int64(content.count), downloadedAt: Date(), lastAccessedAt: Date(), policy: .pinned))
    }
    do {
        try protectedService.moveDirectoryCache(from: "/move-dir", to: "/taken")
        throw CacheIntegrityFailure.assertion("Conflicting directory cache move must propagate failure")
    } catch let error as CocoaError where error.code == .fileWriteFileExists { }
    try require(metadata.get(for: "/move-dir/child")?.policy == .pinned && disk.exists(fileId: "/move-dir/child"), "Failed directory cache move must retain original metadata and content")
    try disk.write(data: content, for: "/root-pinned")
    try healthySync.updateMetadataPersistent(FileMetadata(fileId: "/root-pinned", name: "root-pinned", parentId: "/", isDirectory: false, syncStatus: .synced, etag: "\"confirmed\""))
    protectedService.setCachePolicy(fileId: "/", policy: .pinned)
    do {
        try protectedService.evictFile(fileId: "/root-pinned")
        throw CacheIntegrityFailure.assertion("Root directory pin must protect descendants")
    } catch let error as CocoaError where error.code == .fileWriteNoPermission { }
    print("✅ CAS integrity, cache move preservation, metadata migration and fail-closed eviction passed")
}
