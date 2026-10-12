import Foundation
@testable import CloudDriveCore
@testable import CloudDriveSync
import CloudDriveContracts
import CloudDrivePersistence

private enum StateLifecycleFailure: Error { case assertion(String) }

func runSyncStateLifecycleRegressionTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-state-lifecycle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw StateLifecycleFailure.assertion(message) }
    }
    let bytes = root.appendingPathComponent("local-bytes")
    try Data("local revision".utf8).write(to: bytes)
    let item = VirtualFileItem(id: "/report", name: "report", isDirectory: false, size: 7, modifiedAt: Date(), parentId: "/", syncStatus: .synced, remotePath: "/report", etag: "\"remote\"")
    let unknown = VirtualFileSystem.itemByApplyingSyncMetadata(item, metadata: nil)
    try require(unknown.syncStatus == .cloudOnly, "A mounted DB entry alone must not report a file downloaded")
    var metadata = FileMetadata(fileId: "/report", name: "report", parentId: "/", isDirectory: false, syncStatus: .cloudOnly, localPath: bytes.path, remotePath: "/report", etag: "\"old-local\"", remoteETag: "\"remote\"")
    let stale = VirtualFileSystem.itemByApplyingSyncMetadata(item, metadata: metadata)
    try require(stale.syncStatus == .cloudOnly && stale.etag == "\"remote\"", "Existing stale local bytes must not upgrade cloud-only status or replace latest remote identity")
    metadata.syncStatus = .pendingUpload
    metadata.size = 23
    let pending = VirtualFileSystem.itemByApplyingSyncMetadata(item, metadata: metadata)
    try require(pending.syncStatus == .pendingUpload && pending.size == 23 && pending.etag == "\"old-local\"", "Pending local edits must preserve their local size and baseline revision")
    metadata.syncStatus = .synced
    metadata.localPath = root.appendingPathComponent("missing").path
    try require(VirtualFileSystem.itemByApplyingSyncMetadata(item, metadata: metadata).syncStatus == .cloudOnly, "Missing local bytes must not remain downloaded after remount")
    let unmounted = VirtualFileSystem(vaultId: "not-actively-mounted")
    try require(!unmounted.isVaultMounted(vaultId: "not-actively-mounted"), "A remembered vault ID without an active provider is not a successful mount")

    let queue = OfflineSyncQueue(queueURL: root.appendingPathComponent("queue.db"))
    let store = SyncMetadataStore(metadataURL: root.appendingPathComponent("metadata.db"))
    let service = SyncService(metadataStore: store, queue: queue, automaticallyProcessesQueue: false, notifiesFileProvider: false)
    metadata.syncStatus = .pendingUpload
    metadata.localPath = bytes.path
    metadata.remoteETag = "\"base\""
    metadata.etag = "\"base\""
    try store.updateMetadataPersistent(metadata)
    try service.enqueuePersistent(.upload(fileId: "/report", localPath: bytes.path, remotePath: "/report"), startProcessing: false)
    guard let upload = try queue.nextReadyItem() else { throw StateLifecycleFailure.assertion("Missing accepted upload") }
    _ = try service.withJournalCommit { try service.commitCompletedOperation(upload, result: SyncService.QueueResult(etag: "\"uploaded\"", remotePath: "/report")) }
    let confirmed = try store.getMetadataPersistent(fileId: "/report")
    try require(confirmed?.syncStatus == .synced && confirmed?.etag == "\"uploaded\"" && confirmed?.remoteETag == "\"uploaded\"", "Confirmed upload with accessible local bytes must advance both baseline and current revision")
    metadata.localPath = root.appendingPathComponent("missing").path
    metadata.remoteETag = "\"uploaded\""
    metadata.etag = "\"uploaded\""
    try store.updateMetadataPersistent(metadata)
    let missingLocal = try queue.enqueuePersistent(.upload(fileId: "/report", localPath: bytes.path, remotePath: "/report"), expectedETag: metadata.etag)
    _ = try service.withJournalCommit { try service.commitCompletedOperation(missingLocal, result: SyncService.QueueResult(etag: "\"uploaded-again\"", remotePath: "/report")) }
    try require(try store.getMetadataPersistent(fileId: "/report")?.syncStatus == .cloudOnly, "Remote success alone must not claim missing local content downloaded")

    metadata.localPath = bytes.path
    metadata.etag = "\"base\""
    metadata.remoteETag = "\"base\""
    try store.updateMetadataPersistent(metadata)
    let racing = try queue.enqueuePersistent(.upload(fileId: "/report", localPath: bytes.path, remotePath: "/report"), expectedETag: "\"base\"")
    try store.mutateMetadata(fileId: "/report") { $0.remoteETag = "\"newer-observed\"" }
    _ = try service.withJournalCommit { try service.commitCompletedOperation(racing, result: SyncService.QueueResult(etag: "\"uploaded-response\"", remotePath: "/report")) }
    let raced = try store.getMetadataPersistent(fileId: "/report")
    try require(raced?.etag == "\"uploaded-response\"" && raced?.remoteETag == "\"newer-observed\"" && raced?.syncStatus == .cloudOnly, "Receipt must preserve a newer listing observation instead of treating older confirmed bytes as current")
    let reopened = SyncMetadataStore(metadataURL: root.appendingPathComponent("metadata.db"))
    try require(try reopened.getMetadataPersistent(fileId: "/report")?.remoteETag == "\"newer-observed\"", "Observed remote revision must survive reopening")
    var legacyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as! [String: Any]
    legacyObject.removeValue(forKey: "remoteETag")
    let legacy = try JSONDecoder().decode(FileMetadata.self, from: JSONSerialization.data(withJSONObject: legacyObject))
    try require(legacy.remoteETag == nil, "Legacy JSON without the new revision field must remain readable")
    let legacyDatabase = root.appendingPathComponent("legacy-metadata.db")
    let legacyConnection = SQLiteConnection(dbPath: legacyDatabase)
    try legacyConnection.execute(sql: """
    CREATE TABLE sync_metadata(file_id TEXT PRIMARY KEY, vault_id TEXT, name TEXT NOT NULL,
      parent_id TEXT NOT NULL, is_directory INTEGER NOT NULL DEFAULT 0, sync_status TEXT NOT NULL,
      local_path TEXT, remote_path TEXT, size INTEGER NOT NULL DEFAULT 0, local_modified_at REAL,
      remote_modified_at REAL, etag TEXT, download_progress REAL NOT NULL DEFAULT 0,
      upload_progress REAL NOT NULL DEFAULT 0, last_sync_time REAL);
    INSERT INTO sync_metadata(file_id,name,parent_id,sync_status,etag) VALUES('/legacy','legacy','/','cloudOnly','legacy-baseline');
    """)
    legacyConnection.close()
    let migratedStore = SyncMetadataStore(metadataURL: legacyDatabase)
    var migrated = try migratedStore.getMetadataPersistent(fileId: "/legacy")
    try require(migrated?.etag == "legacy-baseline" && migrated?.remoteETag == nil, "SQLite schema upgrade must preserve historical baseline rows")
    migrated!.remoteETag = "newly-observed"
    try migratedStore.updateMetadataPersistent(migrated!)
    let migratedReopened = SyncMetadataStore(metadataURL: legacyDatabase)
    try require(try migratedReopened.getMetadataPersistent(fileId: "/legacy")?.remoteETag == "newly-observed", "Migrated SQLite schema must persist the independent current remote revision")
    var stagedRename = metadata
    stagedRename.syncStatus = .pendingUpload
    stagedRename.localPath = bytes.path
    try store.updateMetadataPersistent(stagedRename)
    store.moveMetadata(from: "/report", to: "/renamed", newParentId: "/", newName: "renamed", newRemotePath: "/renamed", fallbackStatus: .pendingMove)
    try require(try store.getMetadataPersistent(fileId: "/renamed")?.localPath == bytes.path, "Renaming an accepted edit must retain its immutable staging reference")
    let stagedChild = FileMetadata(fileId: "/parent/child", name: "child", parentId: "/parent", isDirectory: false, syncStatus: .pendingUpload, localPath: bytes.path, remotePath: "/parent/child")
    try store.updateMetadataPersistent(stagedChild)
    store.moveDirectoryMetadata(from: "/parent", to: "/new-parent", newParentId: "/", newName: "new-parent", newRemotePath: "/new-parent")
    try require(try store.getMetadataPersistent(fileId: "/new-parent/child")?.localPath == bytes.path, "Moving a parent must retain staged descendant payloads instead of inventing cache paths")
    try require(SyncService.pendingStatus(for: .move(itemId: "/report", sourceRemotePath: "/a", targetRemotePath: "/b")) == .pendingMove && SyncService.pendingStatus(for: .delete(fileId: "/report", remotePath: "/report")) == .pendingDelete && SyncService.pendingStatus(for: .download(fileId: "/report", remotePath: "/report", localPath: bytes.path)) == .cloudOnly, "Transient failures must keep their operation-specific status")
    try require(SyncService.isPermanentError(StorageError.indeterminateMutation("unknown collection deletion"), retryCount: 0), "An unknown unversioned mutation must remain blocked until explicitly reviewed")
    print("✅ Mount, local availability, confirmed revision and transient-operation state lifecycle passed")
}
