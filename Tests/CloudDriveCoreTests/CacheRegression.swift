import Foundation
import CloudDriveCore
import CloudDriveStorage

private final class CacheRegressionNetwork: NetworkMonitorServiceProtocol, @unchecked Sendable {
    var currentStatus: NetworkStatus { .offline }
    var isOnline: Bool { false }
    func startMonitoring() {}
    func stopMonitoring() {}
    func onStatusChanged(_ handler: @escaping @Sendable (NetworkStatus) -> Void) {}
}
private struct CacheRegressionFailure: Error { let message: String }

/// All stores and payloads live in a fresh temporary directory; no shared cache or quota is modified.
public func runCacheRegressionTests() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudDrive-cache-regression-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var checks = 0
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CacheRegressionFailure(message: message) }
        checks += 1
    }
    func makeService(_ folder: String, maximum: Int64 = 8) -> (CacheService, SyncManager) {
        let directory = root.appendingPathComponent(folder)
        let sync = SyncManager(service: SyncService(
            metadataStore: SyncMetadataStore(metadataURL: directory.appendingPathComponent("sync.json")),
            queue: OfflineSyncQueue(queueURL: directory.appendingPathComponent("queue.json")),
            networkMonitor: CacheRegressionNetwork(),
            automaticallyProcessesQueue: false, notifiesFileProvider: false
        ))
        return (CacheService(storage: CacheDiskStorage(cacheDirectory: directory.appendingPathComponent("Files")), metadataStore: CacheMetadataStore(metadataURL: directory.appendingPathComponent("cache.json")), notifier: CacheNotificationService(vaultId: "regression"), syncManager: sync, maximumCacheSize: maximum), sync)
    }
    let (first, sync) = makeService("first")
    let (second, _) = makeService("second")
    try first.cacheFile(fileId: "/same.txt", data: Data("first vault".utf8))
    try second.cacheFile(fileId: "/same.txt", data: Data("second vault".utf8))
    try check(try first.readCachedFile(fileId: "/same.txt") == Data("first vault".utf8), "Different vault caches must not overwrite the same item path")
    try check(first.localPath(for: "/same.txt") != second.localPath(for: "/same.txt"), "Cache paths are isolated")
    try check(first.isCached(fileId: "/same.txt"), "A newly downloaded file larger than the budget remains deliverable")

    first.pinFile(fileId: "/offline.txt")
    let reopened = CacheMetadataStore(metadataURL: root.appendingPathComponent("first/cache.json"))
    try check(reopened.get(for: "/offline.txt")?.policy == .pinned, "Pinning an undownloaded file persists intent")
    first.reconciler.reconcile()
    try check(first.getCacheMetadata(fileId: "/offline.txt")?.policy == .pinned, "Reconciliation does not discard undownloaded pin intent")
    first.pinFile(fileId: "/folder")
    try first.cacheFile(fileId: "/folder/child.txt", data: Data("child".utf8))
    try check(first.effectivePolicy(fileId: "/folder/child.txt") == .pinned, "Folder pin is inherited by newly downloaded children")
    first.unpinFile(fileId: "/folder")
    try check(first.effectivePolicy(fileId: "/folder/child.txt") == .automatic, "Unpinning a folder releases inherited child policies")

    sync.updateMetadata(FileMetadata(fileId: "/dirty.txt", name: "dirty.txt", parentId: "ROOT", isDirectory: false, syncStatus: .pendingUpload))
    try first.cacheFile(fileId: "/dirty.txt", data: Data("unuploaded edit".utf8))
    try first.cleanupIfNeeded()
    try check(first.isCached(fileId: "/dirty.txt"), "Quota cleanup protects pending uploads")
    try first.clearAllCache()
    try check(first.isCached(fileId: "/dirty.txt") && sync.getMetadata(fileId: "/dirty.txt")?.syncStatus == .pendingUpload, "Clearing cache preserves unsynced bytes and status")
    do { try first.evictFile(fileId: "/dirty.txt"); throw CacheRegressionFailure(message: "Dirty eviction must fail") }
    catch is CocoaError { checks += 1 }

    let (leases, _) = makeService("lease")
    try leases.cacheFile(fileId: "/in-use.txt", data: Data("active handoff".utf8))
    leases.beginAccess(fileId: "/in-use.txt")
    let anotherProcess = CacheService(storage: CacheDiskStorage(cacheDirectory: root.appendingPathComponent("lease/Files")), metadataStore: CacheMetadataStore(metadataURL: root.appendingPathComponent("lease/cache.json")), notifier: CacheNotificationService(vaultId: "regression"), syncManager: SyncManager(service: SyncService(metadataStore: SyncMetadataStore(metadataURL: root.appendingPathComponent("lease/sync.json")), queue: OfflineSyncQueue(queueURL: root.appendingPathComponent("lease/queue.json")), networkMonitor: CacheRegressionNetwork(), automaticallyProcessesQueue: false, notifiesFileProvider: false)), maximumCacheSize: 8)
    try anotherProcess.cleanupIfNeeded()
    try check(leases.isCached(fileId: "/in-use.txt"), "A lease in another cache instance prevents eviction")
    leases.endAccess(fileId: "/in-use.txt")
    try anotherProcess.cleanupIfNeeded()
    try check(!leases.isCached(fileId: "/in-use.txt"), "Clean files can be evicted after their lease ends")

    let metadataURL = root.appendingPathComponent("transaction/cache.json")
    let writer = CacheMetadataStore(metadataURL: metadataURL)
    let staleReader = CacheMetadataStore(metadataURL: metadataURL)
    writer.setPolicy(for: "/keep.txt", policy: .pinned)
    _ = staleReader.getAllMetadata()
    _ = writer.remove(for: "/keep.txt")
    staleReader.setPolicy(for: "/other.txt", policy: .pinned)
    try check(writer.get(for: "/keep.txt") == nil, "A later write cannot resurrect a deleted metadata entry")
    try check(writer.get(for: "/other.txt")?.policy == .pinned, "Independent metadata stores observe the latest policy")

    let storage = CacheDiskStorage(cacheDirectory: root.appendingPathComponent("atomic/Files"))
    try storage.write(data: Data("original".utf8), for: "/file.txt")
    _ = try storage.cache(from: storage.localPath(for: "/file.txt"), for: "/file.txt")
    try check(try storage.read(fileId: "/file.txt") == Data("original".utf8), "Caching an already-cached URL does not delete its own source")
    do { _ = try storage.cache(from: root.appendingPathComponent("missing"), for: "/file.txt"); throw CacheRegressionFailure(message: "Missing source must fail") }
    catch is CocoaError { checks += 1 }
    try check(try storage.read(fileId: "/file.txt") == Data("original".utf8), "A failed replacement retains the previous cache bytes")

    // CAS Content-Addressable Storage & APFS CoW Deduplication test
    let casStorage = CacheDiskStorage(cacheDirectory: root.appendingPathComponent("cas/Files"))
    let testData = Data("identical content for deduplication test 2026".utf8)
    try casStorage.write(data: testData, for: "/fileA.txt")
    try casStorage.write(data: testData, for: "/fileB.txt")
    try casStorage.write(data: testData, for: "/fileC.txt")

    try check(try casStorage.read(fileId: "/fileA.txt") == testData, "CAS fileA reads back correct data")
    try check(try casStorage.read(fileId: "/fileB.txt") == testData, "CAS fileB reads back correct data")
    try check(try casStorage.read(fileId: "/fileC.txt") == testData, "CAS fileC reads back correct data")

    let blobsDir = casStorage.blobsDirectory
    let enumerator = FileManager.default.enumerator(at: blobsDir, includingPropertiesForKeys: [.isRegularFileKey])
    var blobCount = 0
    while let fileURL = enumerator?.nextObject() as? URL {
        let isFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
        if isFile { blobCount += 1 }
    }
    try check(blobCount == 1, "3 identical files must share exactly 1 physical CAS blob on disk (got \(blobCount))")

    // Verify totalDiskSize and currentCacheSize
    let measuredDiskSize = casStorage.totalDiskSize()
    try check(measuredDiskSize >= Int64(testData.count), "totalDiskSize must accurately report disk cache size (got \(measuredDiskSize))")
    
    // Reconciliation and cache size accuracy test
    let (reconService, _) = makeService("reconcile_test", maximum: 1024 * 1024)
    try reconService.cacheFile(fileId: "unprefixed_id.txt", data: Data("1234567890".utf8))
    try reconService.cacheFile(fileId: "/prefixed_id.txt", data: Data("abcdefghij".utf8))
    try check(reconService.currentCacheSize() >= 20, "currentCacheSize must reflect cached files (got \(reconService.currentCacheSize()))")
    
    // Run reconciliation and verify non-prefixed file wasn't purged
    reconService.reconciler.reconcile()
    try check(reconService.isCached(fileId: "unprefixed_id.txt"), "Reconciler must preserve non-prefixed cached files")
    try check(reconService.isCached(fileId: "/prefixed_id.txt"), "Reconciler must preserve prefixed cached files")
    try check(reconService.currentCacheSize() >= 20, "currentCacheSize remains accurate after reconcile (got \(reconService.currentCacheSize()))")

    print("  ✅ Cache regression: \(checks) checks passed")
}
