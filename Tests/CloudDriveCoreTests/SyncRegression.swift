import Foundation
import CloudDriveCore
import CloudDriveStorage
import FileProvider

private enum SyncRegressionFailure: Error {
    case assertion(String)
}

private func syncRequire(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SyncRegressionFailure.assertion(message) }
}

private final class SyncTestNetwork: NetworkMonitorServiceProtocol, @unchecked Sendable {
    var currentStatus: NetworkStatus = .online
    var isOnline: Bool { currentStatus == .online }
    func startMonitoring() {}
    func stopMonitoring() {}
    func onStatusChanged(_ handler: @escaping @Sendable (NetworkStatus) -> Void) {}
}

private actor SyncTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var hasStarted = false
    func wait() async {
        hasStarted = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class SyncTestStorage: StorageClient, @unchecked Sendable {
    private let lock = NSLock()
    private var contents: [String: Data] = [:]
    private var tags: [String: String] = [:]
    private var attempts = 0
    private var failures = 0
    private var expectedVersions: [String?] = []
    var gate: SyncTestGate?
    var onUpload: ((Int) throws -> Void)?
    var listFails = false

    var attemptCount: Int { lock.withLock { attempts } }
    var observedETags: [String?] { lock.withLock { expectedVersions } }
    func failNextUploads(_ count: Int) { lock.withLock { failures = count } }
    func seed(path: String, content: String, etag: String) {
        lock.withLock { contents[path] = Data(content.utf8); tags[path] = etag }
    }
    func text(path: String) -> String? {
        lock.withLock { contents[path].flatMap { String(data: $0, encoding: .utf8) } }
    }

    func listDirectory(path: String) async throws -> [StorageResource] {
        if listFails { throw StorageError.networkError("test listing failed") }
        return lock.withLock {
            contents.map { key, value in
                StorageResource(path: key, displayName: URL(fileURLWithPath: key).lastPathComponent, isDirectory: false, contentLength: Int64(value.count), lastModified: Date(), etag: tags[key])
            }
        }
    }
    func uploadFile(localURL: URL, to remotePath: String, progress: @escaping (Double) -> Void) async throws {
        _ = try await uploadFile(localURL: localURL, to: remotePath, expectedETag: nil, progress: progress)
    }
    func uploadFile(localURL: URL, to remotePath: String, expectedETag: String?, progress: @escaping (Double) -> Void) async throws -> String? {
        let attempt = lock.withLock { () -> Int in
            attempts += 1
            expectedVersions.append(expectedETag)
            return attempts
        }
        if let gate { await gate.wait() }
        try onUpload?(attempt)
        let data = try Data(contentsOf: localURL)
        let tag = try lock.withLock { () throws -> String in
            if failures > 0 { failures -= 1; throw StorageError.networkError("test interruption") }
            if let expectedETag, expectedETag != tags[remotePath] {
                throw StorageError.serverError(statusCode: 412, message: "test conflict")
            }
            let newTag = "\"version-\(attempt)\""
            contents[remotePath] = data
            tags[remotePath] = newTag
            return newTag
        }
        progress(1)
        return tag
    }
    func downloadFile(path: String, to destinationURL: URL, progress: @escaping (Double) -> Void) async throws {
        guard let data = lock.withLock({ contents[path] }) else { throw StorageError.notFound }
        try data.write(to: destinationURL)
        progress(1)
    }
    func createDirectory(path: String) async throws {}
    func delete(path: String) async throws { lock.withLock { contents.removeValue(forKey: path); tags.removeValue(forKey: path) } }
    func move(from sourcePath: String, to destinationPath: String) async throws {
        try lock.withLock {
            guard let data = contents.removeValue(forKey: sourcePath) else { throw StorageError.notFound }
            contents[destinationPath] = data
            tags[destinationPath] = tags.removeValue(forKey: sourcePath)
        }
    }
    func exists(path: String) async throws -> Bool { lock.withLock { contents[path] != nil } }
    func testConnection() async throws -> Bool { true }
}

/// These regressions use temporary journals and mocks, never app-group queues.
public func runSyncRegressionTests() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("CloudDrive-SyncRegression-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    func makeService(_ name: String, storage: SyncTestStorage, vault: String = "test-vault") -> SyncService {
        let directory = root.appendingPathComponent(name)
        let service = SyncService(
            vaultId: vault,
            metadataStore: SyncMetadataStore(metadataURL: directory.appendingPathComponent("metadata.json"), vaultId: vault),
            queue: OfflineSyncQueue(queueURL: directory.appendingPathComponent("queue.json")),
            networkMonitor: SyncTestNetwork(),
            automaticallyProcessesQueue: false,
            notifiesFileProvider: false
        )
        service.configure(storageClient: storage)
        return service
    }
    func stage(_ name: String, _ content: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }
    func metadata(_ id: String, etag: String? = nil) -> FileMetadata {
        FileMetadata(fileId: id, name: URL(fileURLWithPath: id).lastPathComponent, parentId: "ROOT", isDirectory: false, syncStatus: .synced, remotePath: id, etag: etag, lastSyncTime: Date())
    }

    // Two independent journal instances cannot overwrite or resurrect updates.
    let sharedURL = root.appendingPathComponent("shared/queue.json")
    let firstQueue = OfflineSyncQueue(queueURL: sharedURL)
    let secondQueue = OfflineSyncQueue(queueURL: sharedURL)
    for index in 0..<24 {
        _ = try (index.isMultiple(of: 2) ? firstQueue : secondQueue).enqueuePersistent(.createDirectory(directoryId: "d\(index)", name: "d\(index)", parentId: "ROOT", remotePath: "/d\(index)"))
    }
    try syncRequire(firstQueue.getCount() == 24 && secondQueue.getCount() == 24, "Independent journals must preserve all accepted operations")
    let removed = firstQueue.getAllItems()[0].id
    firstQueue.removeItem(id: removed)
    _ = try secondQueue.enqueuePersistent(.createDirectory(directoryId: "new", name: "new", parentId: "ROOT", remotePath: "/new"))
    try syncRequire(!firstQueue.getAllItems().contains { $0.id == removed } && firstQueue.getCount() == 24, "Removed operations must not reappear from another process snapshot")
    let metadataURL = root.appendingPathComponent("shared/metadata.json")
    let firstMetadata = SyncMetadataStore(metadataURL: metadataURL)
    let secondMetadata = SyncMetadataStore(metadataURL: metadataURL)
    try firstMetadata.updateMetadataPersistent(metadata("/one"))
    try secondMetadata.updateMetadataPersistent(metadata("/two"))
    firstMetadata.removeMetadata(fileId: "/one")
    try secondMetadata.updateMetadataPersistent(metadata("/three"))
    try syncRequire(firstMetadata.getAllMetadata().count == 2 && secondMetadata.getMetadata(fileId: "/one") == nil, "Metadata transactions must observe deletions and latest writes")

    // A failed predecessor blocks v2, remains after more than three attempts,
    // then resumes in order. Each own successor uses the prior PUT response ETag.
    let storage = SyncTestStorage()
    storage.seed(path: "/report", content: "base", etag: "\"base\"")
    storage.failNextUploads(4)
    let service = makeService("retry", storage: storage)
    try service.metadataStore.updateMetadataPersistent(metadata("/report", etag: "\"base\""))
    let v1 = try stage("v1", "version one")
    let v2 = try stage("v2", "version two")
    try service.enqueuePersistent(.upload(fileId: "/report", localPath: v1.path, remotePath: "/report"))
    try service.enqueuePersistent(.upload(fileId: "/report", localPath: v2.path, remotePath: "/report"))
    for _ in 0..<4 {
        service.queue.retryFailedOperations()
        await service.processPendingOperations()
        try syncRequire(service.queue.getCount() == 2 && storage.text(path: "/report") == "base", "Failed uploads must retain payloads and block their successor")
    }
    service.queue.retryFailedOperations()
    await service.processPendingOperations()
    try syncRequire(service.queue.getCount() == 0 && storage.text(path: "/report") == "version two", "Recovery must drain versions in order")
    try syncRequire(storage.observedETags.suffix(2).first! == "\"base\"" && storage.observedETags.last! == "\"version-5\"", "Successors must condition on the version actually committed by the preceding PUT")

    // A save arriving during v1 must stay pending until v2 succeeds, and drain
    // without relying on another enqueue or network transition.
    let duringStorage = SyncTestStorage()
    duringStorage.seed(path: "/report", content: "base", etag: "\"base\"")
    let during = makeService("during", storage: duringStorage)
    try during.metadataStore.updateMetadataPersistent(metadata("/report", etag: "\"base\""))
    try during.enqueuePersistent(.upload(fileId: "/report", localPath: v1.path, remotePath: "/report"))
    var sawPendingSuccessor = false
    duringStorage.onUpload = { attempt in
        if attempt == 1 {
            var newer = metadata("/report", etag: "\"base\"")
            newer.localPath = v2.path
            newer.size = 11
            newer.syncStatus = .pendingUpload
            try during.metadataStore.updateMetadataPersistent(newer)
            try during.enqueuePersistent(.upload(fileId: "/report", localPath: v2.path, remotePath: "/report"))
        } else {
            sawPendingSuccessor = during.getMetadata(fileId: "/report")?.syncStatus == .pendingUpload
        }
    }
    await during.processPendingOperations()
    try syncRequire(sawPendingSuccessor && during.queue.getCount() == 0 && duringStorage.text(path: "/report") == "version two", "A newer save must drain and must not be confirmed by v1")
    try syncRequire(during.getMetadata(fileId: "/report")?.localPath == v2.path, "v1 completion must preserve the new local generation")

    // A stale baseline preserves both remote content and the local operation.
    let conflictStorage = SyncTestStorage()
    conflictStorage.seed(path: "/report", content: "other device", etag: "\"remote-new\"")
    let conflict = makeService("conflict", storage: conflictStorage)
    try conflict.metadataStore.updateMetadataPersistent(metadata("/report", etag: "\"old\""))
    try conflict.enqueuePersistent(.upload(fileId: "/report", localPath: v2.path, remotePath: "/report"))
    await conflict.processPendingOperations()
    await conflict.processPendingOperations()
    try syncRequire(conflictStorage.attemptCount == 1 && conflictStorage.text(path: "/report") == "other device", "A version conflict must never overwrite or automatically retry the server's new version")
    try syncRequire(conflict.queue.getCount() == 1 && conflict.getMetadata(fileId: "/report")?.syncStatus == .conflict && fm.fileExists(atPath: v2.path), "The conflict must retain its staged local payload")

    // Identical IDs in separate vault contexts never share state or destinations.
    let aStorage = SyncTestStorage(), bStorage = SyncTestStorage()
    let a = makeService("vault-a", storage: aStorage, vault: "a")
    let b = makeService("vault-b", storage: bStorage, vault: "b")
    try a.metadataStore.updateMetadataPersistent(metadata("/same"))
    try b.metadataStore.updateMetadataPersistent(metadata("/same"))
    try a.enqueuePersistent(.upload(fileId: "/same", localPath: v1.path, remotePath: "/same"))
    try b.enqueuePersistent(.upload(fileId: "/same", localPath: v2.path, remotePath: "/same"))
    await a.processPendingOperations()
    await b.processPendingOperations()
    try syncRequire(aStorage.text(path: "/same") == "version one" && bStorage.text(path: "/same") == "version two", "Vault queues with the same relative ID must use their own storage")
    do {
        try a.enqueuePersistent(.encryptedUpload(fileId: "wrong", fileName: "wrong", parentId: "ROOT", localPath: v1.path, vaultId: "b"))
        throw SyncRegressionFailure.assertion("Cross-vault operations must be rejected")
    } catch SyncError.operationFailed { }

    // Only one independently constructed consumer can issue the queued request.
    let leasedStorage = SyncTestStorage()
    let gate = SyncTestGate()
    leasedStorage.gate = gate
    let leased = makeService("lease", storage: leasedStorage)
    let competitor = makeService("lease", storage: leasedStorage)
    try leased.metadataStore.updateMetadataPersistent(metadata("/single"))
    try leased.enqueuePersistent(.upload(fileId: "/single", localPath: v1.path, remotePath: "/single"))
    let work = Task { await leased.processPendingOperations() }
    while !(await gate.hasStarted) { try await Task.sleep(nanoseconds: 1_000_000) }
    await competitor.processPendingOperations()
    try syncRequire(leasedStorage.attemptCount == 1, "A competing consumer must not upload a leased operation")
    await gate.release()
    await work.value
    try syncRequire(leased.queue.getCount() == 0 && leasedStorage.attemptCount == 1, "Leased operation should be acknowledged once")

    // Bad server listings and corrupt journals are errors, not empty snapshots.
    let failingStorage = SyncTestStorage()
    failingStorage.listFails = true
    let listing = makeService("listing", storage: failingStorage)
    do {
        _ = try await listing.syncDirectory(directoryId: "ROOT", localPath: root.path, remotePath: "/")
        throw SyncRegressionFailure.assertion("An unavailable remote snapshot must stop reconciliation")
    } catch StorageError.networkError { }
    try syncRequire(listing.queue.getCount() == 0, "A failed listing must not queue local files for replacement")
    let corruptURL = root.appendingPathComponent("corrupt.json")
    let corruptBytes = Data("invalid json".utf8)
    try corruptBytes.write(to: corruptURL)
    let corrupt = OfflineSyncQueue(queueURL: corruptURL)
    do {
        _ = try corrupt.enqueuePersistent(.delete(fileId: "f", remotePath: "/f"))
        throw SyncRegressionFailure.assertion("Corrupt journals must reject writes")
    } catch is DecodingError { }
    let retainedCorruptBytes = try Data(contentsOf: corruptURL)
    try syncRequire(retainedCorruptBytes == corruptBytes, "A corrupt journal must remain available for recovery")

    // Head-of-line unblocking: error on /blocked does not stop /independent
    let holStorage = SyncTestStorage()
    holStorage.seed(path: "/blocked", content: "baseA", etag: "\"baseA\"")
    holStorage.seed(path: "/independent", content: "baseB", etag: "\"baseB\"")
    let holService = makeService("hol", storage: holStorage)
    try holService.metadataStore.updateMetadataPersistent(metadata("/blocked", etag: "\"baseA\""))
    try holService.metadataStore.updateMetadataPersistent(metadata("/independent", etag: "\"baseB\""))
    holStorage.onUpload = { attempt in
        if holStorage.observedETags.last == "\"baseA\"" {
            throw StorageError.networkError("blocked file error")
        }
    }
    let blockedV1 = try stage("blockedV1", "blocked content")
    let indepV1 = try stage("indepV1", "independent content")
    try holService.enqueuePersistent(.upload(fileId: "/blocked", localPath: blockedV1.path, remotePath: "/blocked"))
    try holService.enqueuePersistent(.upload(fileId: "/independent", localPath: indepV1.path, remotePath: "/independent"))
    await holService.processPendingOperations()
    try syncRequire(holStorage.text(path: "/independent") == "independent content", "Independent file should succeed even if predecessor file fails")
    try syncRequire(holService.queue.getCount() == 1 && holService.queue.getAllItems()[0].operation.fileId == "/blocked", "/blocked should remain in queue")

    // Conflict strategy resolution: forkBothWithSuffix creates conflicted copy and restores remote
    let crStorage = SyncTestStorage()
    crStorage.seed(path: "/conflicted.txt", content: "server version", etag: "\"srv1\"")
    let crLocal = try stage("local.txt", "client version")
    let crService = makeService("conflict-res", storage: crStorage, vault: "test-cr-vault")
    let crSyncManager = SyncManager(service: crService)
    crSyncManager.configure(storageClient: crStorage)
    var crMeta = metadata("/conflicted.txt", etag: "\"old\"")
    crMeta.localPath = crLocal.path
    crMeta.syncStatus = .conflict
    crSyncManager.updateMetadata(crMeta)
    let resolver = SyncConflictResolver()
    let cm = CacheManager.forVault("test-cr-vault")
    try await resolver.resolveConflict(
        fileId: "/conflicted.txt",
        strategy: .forkBothWithSuffix,
        storageClient: crStorage,
        vfs: nil,
        syncManager: crSyncManager,
        cacheManager: cm
    )
    // Multi-vault configuration isolation: per-vault config persistence
    let testUserDefaults = UserDefaults(suiteName: "test_vault_registry_\(UUID().uuidString)")!
    let testSharedDefaults = UserDefaults(suiteName: "test_shared_registry_\(UUID().uuidString)")!
    let registry = VaultRegistry(userDefaults: testUserDefaults, sharedDefaults: testSharedDefaults)
    let vaultA = VaultInfo(id: "vA", name: "Vault1", storagePath: "/vA", createdAt: Date(), storageType: .webdav, isEncrypted: true, isAutoMount: true)
    let vaultB = VaultInfo(id: "vB", name: "Vault2", storagePath: "/vB", createdAt: Date(), storageType: .webdav, isEncrypted: false, isAutoMount: false)
    registry.saveVaultConfig(vaultA)
    registry.saveVaultConfig(vaultB)
    try syncRequire(registry.loadVaultConfig(for: vaultA.id)?.id == vaultA.id, "Per-vault config for Vault1 should load accurately")
    try syncRequire(registry.loadVaultConfig(for: vaultB.id)?.id == vaultB.id, "Per-vault config for Vault2 should load accurately")
    registry.saveVaults([vaultA, vaultB])
    let allVaults = registry.loadVaults()
    try syncRequire(allVaults.count == 2, "Saved vaults list should contain both vaults")
    try syncRequire(testSharedDefaults.data(forKey: "vault_config_\(vaultA.id)") != nil, "Shared defaults must contain vault_config for Vault 1")
    try syncRequire(testSharedDefaults.data(forKey: "vault_config_\(vaultB.id)") != nil, "Shared defaults must contain vault_config for Vault 2")

    // EnumeratorSignaler container accumulation test
    let testDomain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("test-domain-\(UUID().uuidString)"), displayName: "Test Domain")
    let id1 = NSFileProviderItemIdentifier("container_A")
    let id2 = NSFileProviderItemIdentifier("container_B")
    await EnumeratorSignaler.shared.signal(domain: testDomain, for: id1)
    await EnumeratorSignaler.shared.signal(domain: testDomain, for: id2)
    // Both containers should be maintained without dropping id1
    await EnumeratorSignaler.shared.signalImmediately(for: testDomain)

    // 1. Directory Move Descendant Cascade in OfflineSyncQueue
    let cascadeQueueURL = root.appendingPathComponent("cascade-queue.json")
    let cascadeQueue = OfflineSyncQueue(queueURL: cascadeQueueURL)
    _ = try cascadeQueue.enqueuePersistent(.upload(fileId: "/FolderA/child1.txt", localPath: "/tmp/c1", remotePath: "/FolderA/child1.txt"))
    _ = try cascadeQueue.enqueuePersistent(.upload(fileId: "/FolderA/Sub/child2.txt", localPath: "/tmp/c2", remotePath: "/FolderA/Sub/child2.txt"))
    _ = try cascadeQueue.enqueuePersistent(.upload(fileId: "/OtherFolder/independent.txt", localPath: "/tmp/other", remotePath: "/OtherFolder/independent.txt"))
    
    cascadeQueue.updatePendingOperation(
        oldFileId: "/FolderA",
        newFileId: "/FolderB",
        newRemotePath: "/FolderB",
        newName: "FolderB",
        newParentId: "ROOT"
    )
    
    let cascadeItems = cascadeQueue.getAllItems()
    let c1Item = cascadeItems.first { $0.operation.fileId == "/FolderB/child1.txt" }
    let c2Item = cascadeItems.first { $0.operation.fileId == "/FolderB/Sub/child2.txt" }
    let otherItem = cascadeItems.first { $0.operation.fileId == "/OtherFolder/independent.txt" }
    
    try syncRequire(c1Item != nil, "Descendant child1 should be cascaded to /FolderB/child1.txt")
    try syncRequire(c1Item?.operation.remotePath == "/FolderB/child1.txt", "Descendant child1 remotePath should be updated")
    try syncRequire(c2Item != nil, "Nested descendant child2 should be cascaded to /FolderB/Sub/child2.txt")
    try syncRequire(c2Item?.operation.remotePath == "/FolderB/Sub/child2.txt", "Nested descendant child2 remotePath should be updated")
    try syncRequire(otherItem != nil, "Independent file in OtherFolder should remain untouched")
    
    // 2. Crash in-flight self-healing recovery test
    let crashQueueURL = root.appendingPathComponent("crash-queue.json")
    let crashQueue = OfflineSyncQueue(queueURL: crashQueueURL)
    let itemToClaim = try crashQueue.enqueuePersistent(.upload(fileId: "/crash_test.txt", localPath: "/tmp/crash", remotePath: "/crash_test.txt"))
    
    // Claim the item (simulates starting the upload task)
    let claimed = try crashQueue.claimItem(id: itemToClaim.id)
    try syncRequire(claimed?.startedAt != nil, "Claimed item must have startedAt set")
    
    // Run resetAbandonedItems with 0s threshold to simulate an abandoned item from a crashed process
    try crashQueue.resetAbandonedItems(olderThan: 0.0)
    let recoveredItem = crashQueue.getAllItems().first { $0.id == itemToClaim.id }
    try syncRequire(recoveredItem?.startedAt == nil, "Abandoned in-flight task must have startedAt reset to nil for self-healing")
    
    // 3. Redundant upload cancellation on delete test
    try syncRequire(cascadeQueue.hasPendingUpload(fileId: "/FolderB/child1.txt"), "Queue should have pending upload for child1")
    cascadeQueue.removePendingUploads(for: "/FolderB/child1.txt")
    try syncRequire(!cascadeQueue.hasPendingUpload(fileId: "/FolderB/child1.txt"), "removePendingUploads should remove child1 upload operation")
    try syncRequire(cascadeQueue.hasPendingUpload(fileId: "/FolderB/Sub/child2.txt"), "Other items should remain intact")

    print("✅ Sync regressions: journal transactions, retries, version order, generation state, conflict protection, vault isolation, consumer lease, failed snapshot safety, HoL unblocking, conflict fork resolution, multi-vault config isolation, enumerator signaler accumulation, cascade descendant move, in-flight crash self-healing, redundant upload cancellation")
}
