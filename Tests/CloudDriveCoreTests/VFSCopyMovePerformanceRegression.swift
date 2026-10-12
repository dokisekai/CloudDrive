import Foundation
import CloudDriveCore
import CloudDriveVFS
import CloudDriveCache
import CloudDriveContracts
import CloudDrivePersistence

private enum CopyPerformanceFailure: Error { case assertion(String) }
private final class CopyPerformanceNetwork: NetworkMonitorServiceProtocol, @unchecked Sendable {
    let currentStatus: NetworkStatus = .online
    let isOnline = true
    func startMonitoring() {}
    func stopMonitoring() {}
    func onStatusChanged(_ handler: @escaping @Sendable (NetworkStatus) -> Void) {}
}
private final class CopyPerformanceStorage: StorageClient {
    let requiresETagForUpdate = true
    var copies = 0
    var moves = 0
    var returnedETag: String? = "\"copied\""
    var sourceTags: [String?] = []
    var duringCopy: (() throws -> Void)?
    func listDirectory(path: String) async throws -> [StorageResource] { [] }
    func downloadFile(path: String, to destinationURL: URL, progress: @escaping (Double) -> Void) async throws { throw CopyPerformanceFailure.assertion("COPY downloaded content") }
    func uploadFile(localURL: URL, to remotePath: String, progress: @escaping (Double) -> Void) async throws { throw CopyPerformanceFailure.assertion("COPY uploaded content") }
    func createDirectory(path: String) async throws {}
    func delete(path: String) async throws { throw CopyPerformanceFailure.assertion("Unexpected DELETE") }
    func move(from sourcePath: String, to destinationPath: String) async throws { moves += 1 }
    func copy(from sourcePath: String, to destinationPath: String, expectedETag: String?) async throws -> String? {
        copies += 1
        sourceTags.append(expectedETag)
        try duringCopy?()
        return returnedETag
    }
    func exists(path: String) async throws -> Bool { true }
}

func runVFSCopyMovePerformanceRegressionTests() async throws {
    func require(_ value: Bool, _ message: String) throws { if !value { throw CopyPerformanceFailure.assertion(message) } }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vfs-copy-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = VFSDatabase(vaultId: "fixture", directory: root.appendingPathComponent("vfs"))
    try database.initialize(vaultId: "fixture", basePath: "/dav")
    let sync = SyncManager(service: SyncService(vaultId: "fixture", metadataStore: SyncMetadataStore(metadataURL: root.appendingPathComponent("sync.json"), vaultId: "fixture"), queue: OfflineSyncQueue(queueURL: root.appendingPathComponent("queue.json")), networkMonitor: CopyPerformanceNetwork(), automaticallyProcessesQueue: false, notifiesFileProvider: false))
    let cache = CacheManager(service: CacheService(storage: CacheDiskStorage(cacheDirectory: root.appendingPathComponent("files")), metadataStore: CacheMetadataStore(metadataURL: root.appendingPathComponent("cache.json")), notifier: CacheNotificationService(vaultId: "fixture"), syncManager: sync, maximumCacheSize: 1024 * 1024))
    let storage = CopyPerformanceStorage()
    let direct = DirectMappingVFSProvider(vaultId: "fixture", storagePath: "/dav", storageClient: storage, database: database, syncManager: sync, cacheManager: cache, operationManager: FileOperationTracker())
    let payload = root.appendingPathComponent("payload")
    try Data("original".utf8).write(to: payload)
    try database.insertFile(id: "/dav/source", name: "source", parentId: "ROOT", size: 8, encryptedName: "source", remotePath: "/dav/source")
    try cache.cacheFile(fileId: "/dav/source", from: payload, confirmedETag: "\"source\"")
    try sync.updateMetadataPersistent(FileMetadata(fileId: "/dav/source", name: "source", parentId: "ROOT", isDirectory: false, syncStatus: .synced, localPath: cache.localPath(for: "/dav/source").path, remotePath: "/dav/source", size: 8, etag: "\"source\"", remoteETag: "\"source\"", lastSyncTime: Date()))
    let copy = try await direct.copyItem(itemId: "/dav/source", newParentId: "ROOT", newName: "copy")
    try require(storage.copies == 1 && storage.sourceTags == ["\"source\""] && cache.isCached(fileId: copy.id), "Clean copy must use one conditional remote COPY and clone its cache")
    try require((try sync.getMetadataPersistent(fileId: copy.id))?.etag == "\"copied\"", "Cloned cache must bind the destination revision")
    _ = try await direct.moveItem(itemId: "/dav/source", newParentId: "ROOT", newName: "source")
    try require(storage.moves == 0 && cache.isCached(fileId: "/dav/source"), "No-op rename must retain content and skip MOVE")
    storage.returnedETag = nil
    let unknown = try await direct.copyItem(itemId: "/dav/source", newParentId: "ROOT", newName: "unknown")
    try require(unknown.syncStatus == .cloudOnly && !cache.isCached(fileId: unknown.id), "COPY lacking destination revision cannot claim a confirmed local copy")
    var dirty = try sync.getMetadataPersistent(fileId: "/dav/source")!
    dirty.syncStatus = .pendingUpload
    try sync.updateMetadataPersistent(dirty)
    let localCopy = try await direct.copyItem(itemId: "/dav/source", newParentId: "ROOT", newName: "dirty-copy")
    try require(storage.copies == 2 && localCopy.syncStatus == .pendingUpload && sync.hasPendingUpload(fileId: localCopy.id), "Unsynced copy must clone and queue the accepted local bytes")
    let accepted = try sync.getMetadataPersistent(fileId: localCopy.id)!
    try Data("changed".utf8).write(to: cache.localPath(for: "/dav/source"))
    try require(try Data(contentsOf: URL(fileURLWithPath: accepted.localPath!)) == Data("original".utf8), "Source edits cannot change the copied snapshot")
    try cache.removeCachedFile(fileId: copy.id)
    // Fingerprint lookup is bounded and only accepts a confirmed, unchanged generation.
    try cache.cacheFile(fileId: "/dav/source", from: payload, confirmedETag: "\"source\"")
    dirty.syncStatus = .synced
    dirty.etag = "\"source\""
    dirty.remoteETag = dirty.etag
    try sync.updateMetadataPersistent(dirty)
    try cache.cacheFile(fileId: "incoming", from: payload)
    let match = cache.matchingConfirmedSource(for: "incoming")
    try require(match?.fileId == "/dav/source" && match?.etag == "\"source\"", "Identical confirmed content must resolve to its source revision")
    dirty.remoteETag = "\"remote-new\""
    try sync.updateMetadataPersistent(dirty)
    try require(cache.matchingConfirmedSource(for: "incoming")?.fileId != "/dav/source", "Stale remote revision must never authorize content reuse")
    dirty.remoteETag = dirty.etag
    try sync.updateMetadataPersistent(dirty)
    let other = root.appendingPathComponent("different")
    try Data("DIFFERNT".utf8).write(to: other)
    try cache.cacheFile(fileId: "different-input", from: other)
    try require(cache.matchingConfirmedSource(for: "different-input") == nil, "Different bytes must not match a content fingerprint")
    storage.returnedETag = "\"frozen-copy\""
    storage.duringCopy = {
        try cache.cacheFile(fileId: "/dav/source", data: Data("new edit".utf8))
        var changed = dirty
        changed.syncStatus = .pendingUpload
        changed.localModifiedAt = Date()
        try sync.updateMetadataPersistent(changed)
    }
    let frozen = try await direct.copyItem(itemId: "/dav/source", newParentId: "ROOT", newName: "frozen", cachedContentOverride: "incoming", expectedSourceETag: "\"source\"")
    try require(try cache.readCachedFile(fileId: frozen.id) == Data("original".utf8), "COPY must publish the frozen incoming bytes even when the source changes in flight")
    try require((try sync.getMetadataPersistent(fileId: "/dav/source"))?.syncStatus == .pendingUpload, "COPY must preserve the concurrent source edit")
    try require(cache.matchingConfirmedSource(for: "incoming")?.fileId != "/dav/source", "Dirty source must not remain eligible for reuse")
    storage.duringCopy = nil
    try cache.cacheFile(fileId: "/dav/source", from: payload, confirmedETag: "\"source\"")
    try sync.updateMetadataPersistent(dirty)
    storage.duringCopy = {
        var changed = dirty
        changed.syncStatus = .pendingUpload
        changed.localModifiedAt = Date()
        try cache.cacheFile(fileId: "/dav/source", data: Data("new edit".utf8))
        try sync.updateMetadataPersistent(changed)
    }
    let raced = try await direct.copyItem(itemId: "/dav/source", newParentId: "ROOT", newName: "source-race")
    try require(raced.syncStatus == .cloudOnly && !cache.isCached(fileId: raced.id), "Ordinary COPY must not bind a concurrently edited source cache to the remote receipt")
    try cache.cacheFile(fileId: "/dav/source", from: payload, confirmedETag: "\"source\"")
    try sync.updateMetadataPersistent(dirty)
    let targetId = "/dav/target-race"
    storage.duringCopy = {
        let target = FileMetadata(fileId: targetId, name: "target-race", parentId: "ROOT", isDirectory: false,
            syncStatus: .pendingUpload, localPath: payload.path, remotePath: targetId, size: 8, localModifiedAt: Date())
        try sync.acceptSavePersistent(metadata: target, operation: .upload(fileId: targetId, localPath: payload.path, remotePath: targetId), expectedETag: nil) {}
    }
    do {
        _ = try await direct.copyItem(itemId: "/dav/source", newParentId: "ROOT", newName: "target-race")
        throw CopyPerformanceFailure.assertion("COPY must not overwrite a concurrently accepted target edit")
    } catch let error as StorageError {
        try require(error.isPreconditionFailure, "Concurrent COPY target must fail its publication precondition")
    }
    try require((try sync.getMetadataPersistent(fileId: targetId))?.syncStatus == .pendingUpload && sync.hasPendingUpload(fileId: targetId), "Concurrent target metadata and upload intent must survive COPY")
    storage.duringCopy = nil
    print("✅ Conditional server COPY, immutable local copy and no-op MOVE passed")
}
