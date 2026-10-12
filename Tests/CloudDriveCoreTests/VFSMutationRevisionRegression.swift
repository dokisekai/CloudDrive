import Foundation
import CloudDriveCore
import CloudDriveVFS
import CloudDriveCache
import CloudDriveContracts
import CloudDrivePersistence

private enum VFSMutationFailure: Error { case assertion(String) }
private final class MutationRevisionNetwork: NetworkMonitorServiceProtocol, @unchecked Sendable {
    let currentStatus: NetworkStatus = .online
    let isOnline = true
    func startMonitoring() {}
    func stopMonitoring() {}
    func onStatusChanged(_ handler: @escaping @Sendable (NetworkStatus) -> Void) {}
}
private final class MutationRevisionStorage: StorageClient {
    let requiresETagForUpdate = true
    var deleteTags: [String?] = []
    var moveTags: [String?] = []
    func listDirectory(path: String) async throws -> [StorageResource] { [] }
    func downloadFile(path: String, to destinationURL: URL, progress: @escaping (Double) -> Void) async throws {}
    func uploadFile(localURL: URL, to remotePath: String, progress: @escaping (Double) -> Void) async throws { throw VFSMutationFailure.assertion("Blind PUT") }
    func createDirectory(path: String) async throws {}
    func delete(path: String) async throws { throw VFSMutationFailure.assertion("Blind DELETE") }
    func delete(path: String, expectedETag: String?) async throws {
        deleteTags.append(expectedETag)
        throw StorageError.serverError(statusCode: 412, message: "Newer revision")
    }
    func move(from sourcePath: String, to destinationPath: String) async throws { throw VFSMutationFailure.assertion("Blind MOVE") }
    func move(from sourcePath: String, to destinationPath: String, expectedETag: String?) async throws {
        moveTags.append(expectedETag)
        throw StorageError.serverError(statusCode: 412, message: "Newer revision")
    }
    func exists(path: String) async throws -> Bool { true }
}
func runVFSMutationRevisionRegressionTests() async throws {
    func require(_ value: Bool, _ message: String) throws { if !value { throw VFSMutationFailure.assertion(message) } }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vfs-mutation-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = VFSDatabase(vaultId: "fixture", directory: root.appendingPathComponent("vfs"))
    try database.initialize(vaultId: "fixture", basePath: "/dav")
    let sync = SyncManager(service: SyncService(vaultId: "fixture", metadataStore: SyncMetadataStore(metadataURL: root.appendingPathComponent("sync.json"), vaultId: "fixture"), queue: OfflineSyncQueue(queueURL: root.appendingPathComponent("queue.json")), networkMonitor: MutationRevisionNetwork(), automaticallyProcessesQueue: false, notifiesFileProvider: false))
    let cache = CacheManager(service: CacheService(storage: CacheDiskStorage(cacheDirectory: root.appendingPathComponent("files")), metadataStore: CacheMetadataStore(metadataURL: root.appendingPathComponent("cache.json")), notifier: CacheNotificationService(vaultId: "fixture"), syncManager: sync, maximumCacheSize: 1024 * 1024))
    let storage = MutationRevisionStorage()
    let direct = DirectMappingVFSProvider(vaultId: "fixture", storagePath: "/dav", storageClient: storage, database: database, syncManager: sync, cacheManager: cache, operationManager: FileOperationTracker())
    try database.insertFile(id: "/a", name: "a", parentId: "ROOT", size: 1, encryptedName: "a", remotePath: "/a")
    try sync.updateMetadataPersistent(FileMetadata(fileId: "/a", name: "a", parentId: "ROOT", isDirectory: false, syncStatus: .synced, remotePath: "/a", etag: "\"baseline\""))
    var rejected = false
    do { try await direct.delete(itemId: "/a") } catch let error as StorageError { rejected = error.isPreconditionFailure }
    try require(rejected && storage.deleteTags == ["\"baseline\""] && (try database.getFile(id: "/a")) != nil, "Direct deletion must preserve a newer revision and local metadata")
    rejected = false
    do { _ = try await direct.moveItem(itemId: "/a", newParentId: "ROOT", newName: "b") } catch let error as StorageError { rejected = error.isPreconditionFailure }
    try require(rejected && storage.moveTags == ["\"baseline\""] && (try database.getFile(id: "/a")) != nil, "Direct move must send the saved revision and retain the source on conflict")
    try sync.updateMetadataPersistent(FileMetadata(fileId: "/a", name: "a", parentId: "ROOT", isDirectory: false, syncStatus: .synced, remotePath: "/a"))
    rejected = false
    do { try await direct.delete(itemId: "/a") } catch let error as StorageError { rejected = error.isPreconditionFailure }
    try require(rejected && storage.deleteTags.count == 1, "Missing revision must reject before DELETE")
    let key = try VFSEncryption().generateMasterKey(password: "fixture").0
    let format = CryptomatorFormat(masterkey: key, storageClient: storage, basePath: "/dav")
    let encrypted = EncryptedVFSProvider(vaultId: "fixture", cryptomatorFormat: format, storageClient: storage, database: database, syncManager: sync, cacheManager: cache, operationManager: FileOperationTracker())
    try database.insertFile(id: "file_long", name: "long", parentId: "ROOT", size: 1, encryptedName: "long", remotePath: "/old.c9s/contents.c9r")
    try sync.updateMetadataPersistent(FileMetadata(fileId: "file_long", name: "long", parentId: "ROOT", isDirectory: false, syncStatus: .synced, remotePath: "/old.c9s/contents.c9r", etag: "\"baseline\""))
    rejected = false
    do { _ = try await encrypted.moveItem(itemId: "file_long", newParentId: "ROOT", newName: "short") } catch let error as StorageError { rejected = error.isPreconditionFailure }
    try require(rejected && storage.moveTags.last! == "\"baseline\"" && storage.deleteTags.count == 1, "Encrypted move must condition the content object and never blindly clean its wrapper")
    let pipelineSync = SyncService(metadataStore: SyncMetadataStore(metadataURL: root.appendingPathComponent("pipeline-sync.db")), queue: OfflineSyncQueue(queueURL: root.appendingPathComponent("pipeline-queue.db")), automaticallyProcessesQueue: false, notifiesFileProvider: false)
    try pipelineSync.metadataStore.updateMetadataPersistent(FileMetadata(fileId: "/pipeline", name: "pipeline", parentId: "/", isDirectory: false, syncStatus: .synced, etag: "\"pipeline-baseline\""))
    let pipeline = FileDeleter(context: FileOperationContext(storageClient: storage, syncService: pipelineSync, tracker: FileOperationTracker()))
    rejected = false
    do { try await pipeline.delete(remotePath: "/pipeline", fileId: "/pipeline") } catch let error as StorageError { rejected = error.isPreconditionFailure }
    try require(rejected && storage.deleteTags.last! == "\"pipeline-baseline\"", "Deletion pipeline must use the persisted baseline")
    let calls = storage.deleteTags.count
    rejected = false
    do { try await pipeline.delete(remotePath: "/directory", fileId: "/directory", isDirectory: true) } catch let error as StorageError { rejected = error.isPreconditionFailure }
    try require(rejected && calls + 1 == storage.deleteTags.count && storage.deleteTags.last! == nil, "Directory deletion sends one collection DELETE without inventing a version")
    print("✅ Direct/encrypted VFS mutation revision protection passed")
}
