import Foundation
@testable import CloudDriveSync
import CloudDriveContracts
import CloudDrivePersistence
import SQLite3

private enum VersionRegressionFailure: Error { case assertion(String) }
private final class VersionDeletionStorage: StorageClient {
    var requiresETagForUpdate: Bool { true }
    var deleteCalls = 0
    func listDirectory(path: String) async throws -> [StorageResource] { [] }
    func uploadFile(localURL: URL, to remotePath: String, progress: @escaping (Double) -> Void) async throws {}
    func downloadFile(path: String, to destinationURL: URL, progress: @escaping (Double) -> Void) async throws {}
    func createDirectory(path: String) async throws {}
    func delete(path: String) async throws { throw VersionRegressionFailure.assertion("Unconditional delete") }
    func delete(path: String, expectedETag: String?) async throws { deleteCalls += 1 }
    func move(from sourcePath: String, to destinationPath: String) async throws {}
    func exists(path: String) async throws -> Bool { true }
}

func runQueueVersionPerformanceRegressionTests() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("queue-version-performance-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw VersionRegressionFailure.assertion(message) }
    }
    for count in [1000, 10000] {
        let queue = OfflineSyncQueue(queueURL: root.appendingPathComponent("versions-\(count).db"))
        let enqueueStart = Date()
        try queue.conn.withTransaction {
            for _ in 0..<count {
                _ = try queue.enqueuePersistent(.upload(fileId: "/versioned", localPath: "/tmp/report", remotePath: "/versioned"), expectedETag: "\"base\"")
            }
        }
        let enqueueDuration = Date().timeIntervalSince(enqueueStart)
        let edges = try SQLiteStatement(db: try queue.conn.getHandle(), sql: "SELECT COUNT(*) FROM sync_queue_dependency_edges;")
        try require(edges.step() == SQLITE_ROW && edges.columnInt64(at: 0) == Int64(count - 1), "Version dependencies must remain a linear chain")
        let drainStart = Date()
        for version in 0..<count {
            guard let ready = try queue.nextReadyItem() else { throw VersionRegressionFailure.assertion("Missing eligible version") }
            let expected = version == 0 ? "\"base\"" : "\"version-\(version - 1)\""
            try require(ready.expectedETag == expected, "Each version must use the immediately preceding confirmed revision")
            try require(try queue.findMoveSuccessor(sourcePath: "/versioned", excludeId: ready.id) == nil, "Move lookup must skip upload backlog")
            _ = try queue.successorStatus(fileIds: ["/versioned"], excludeId: ready.id)
            _ = try queue.completeItem(id: ready.id, fileId: ready.operation.fileId, etag: "\"version-\(version)\"")
        }
        try require(queue.getCount() == 0, "Version backlog must fully drain")
        print("✅ \(count) same-file versions: enqueue \(enqueueDuration)s, complete \(Date().timeIntervalSince(drainStart))s")
    }
    let cancellation = OfflineSyncQueue(queueURL: root.appendingPathComponent("cancel-confirmed-revision.db"))
    var versions: [SyncQueueItem] = []
    for _ in 0..<3 { versions.append(try cancellation.enqueuePersistent(.upload(fileId: "/report", localPath: "/tmp/report", remotePath: "/report"), expectedETag: "\"base\"")) }
    _ = try cancellation.completeItem(id: versions[0].id, fileId: "/report", etag: "\"confirmed-v1\"")
    _ = try cancellation.removeUnstartedItemsPersistent(ids: [versions[1].id])
    try require(try cancellation.nextReadyItem()?.expectedETag == "\"confirmed-v1\"", "Cancellation must carry a confirmed revision to the remaining successor")
    let deletionThenCreate = OfflineSyncQueue(queueURL: root.appendingPathComponent("delete-create.db"))
    let deletion = try deletionThenCreate.enqueuePersistent(.delete(fileId: "/report", remotePath: "/report"), expectedETag: "\"old\"")
    _ = try deletionThenCreate.enqueuePersistent(.upload(fileId: "/report", localPath: "/tmp/report", remotePath: "/report"), expectedETag: "\"old\"")
    _ = try deletionThenCreate.completeItem(id: deletion.id, fileId: "/report", etag: nil)
    let creation = try deletionThenCreate.nextReadyItem()
    try require(creation != nil && creation?.expectedETag == nil, "Recreation after confirmed DELETE must create conditionally instead of matching a removed revision")

    let replacementQueue = OfflineSyncQueue(queueURL: root.appendingPathComponent("replacement-versions.db"))
    var accepted: SyncQueueItem?
    try replacementQueue.conn.withTransaction {
        for index in 0..<3000 {
            let queued = try replacementQueue.enqueuePersistent(.encryptedUpload(fileId: "pending", fileName: "report", parentId: "ROOT", localPath: "/tmp/report", vaultId: "versions"), expectedETag: "\"base\"")
            if index == 0 { accepted = queued }
        }
    }
    let replacement = VirtualFileItem(id: "confirmed", name: "report", isDirectory: false, size: 0, modifiedAt: Date(), parentId: "ROOT", remotePath: "/confirmed")
    let rewriteStart = Date()
    _ = try replacementQueue.completeItem(id: accepted!.id, fileId: "pending", etag: "\"confirmed-v0\"", replacement: replacement)
    let rewriteDuration = Date().timeIntervalSince(rewriteStart)
    try require(replacementQueue.getCount() == 2999 && (try replacementQueue.itemsForFilePersistent(fileId: "pending")).isEmpty, "Identity replacement must transfer every accepted version")
    for index in 0..<2999 {
        guard let ready = try replacementQueue.nextReadyItem() else { throw VersionRegressionFailure.assertion("Replacement lost version dependencies") }
        try require(ready.operation.fileId == "confirmed" && ready.expectedETag == "\"confirmed-v\(index)\"", "Replacement version chain must preserve identity and revision order")
        _ = try replacementQueue.completeItem(id: ready.id, fileId: "confirmed", etag: "\"confirmed-v\(index + 1)\"", replacement: replacement)
    }
    print("✅ 3,000 encrypted versions: identity transfer \(rewriteDuration)s, complete \(Date().timeIntervalSince(rewriteStart) - rewriteDuration)s")

    let storage = VersionDeletionStorage()
    let service = SyncService(vaultId: "versions", metadataStore: SyncMetadataStore(metadataURL: root.appendingPathComponent("delete-metadata.db")), queue: OfflineSyncQueue(queueURL: root.appendingPathComponent("delete-queue.db")), automaticallyProcessesQueue: false, notifiesFileProvider: false)
    service.configure(storageClient: storage)
    try service.metadataStore.updateMetadataPersistent(FileMetadata(fileId: "/directory", name: "directory", parentId: "/", isDirectory: true, syncStatus: .synced, remotePath: "/directory", etag: "\"directory\""))
    for operation in [SyncOperation.delete(fileId: "/directory", remotePath: "/directory"), .deleteItem(fileId: "/directory", remotePath: "/directory", isDirectory: true, directoryId: nil, vaultId: "versions")] {
        let result = try await service.processQueueItem(SyncQueueItem(operation: operation, expectedETag: "\"directory\"", vaultId: "versions"))
        try require(result.deleted, "Authorized directory intent must complete as one collection deletion")
    }
    try require(storage.deleteCalls == 2, "Each directory deletion intent must send exactly one DELETE")
    do {
        _ = try await service.processQueueItem(SyncQueueItem(operation: .delete(fileId: "/unknown", remotePath: "/unknown"), expectedETag: "\"directory\"", vaultId: "versions"))
        throw VersionRegressionFailure.assertion("Unknown deletion must be rejected")
    } catch StorageError.serverError(let code, _) {
        try require(code == 412, "Unknown file deletion must remain a recoverable conflict")
    }
    try require(storage.deleteCalls == 2, "Unknown deletion must not reach the server")
    print("✅ Confirmed revision cancellation, conditional recreation and single-request directory DELETE passed")
}
