import Foundation
@testable import CloudDriveSync
import CloudDriveContracts

private enum ReconciliationFailure: Error { case assertion(String) }
private final class ReconciliationNetwork: NetworkMonitorServiceProtocol, @unchecked Sendable {
    let currentStatus: NetworkStatus = .online
    let isOnline = true
    func startMonitoring() {}
    func stopMonitoring() {}
    func onStatusChanged(_ handler: @escaping @Sendable (NetworkStatus) -> Void) {}
}
private final class ReconciliationStorage: StorageClient {
    var resources: [StorageResource] = []
    func listDirectory(path: String) async throws -> [StorageResource] { resources }
    func downloadFile(path: String, to destinationURL: URL, progress: @escaping (Double) -> Void) async throws { throw ReconciliationFailure.assertion("Unexpected download") }
    func uploadFile(localURL: URL, to remotePath: String, progress: @escaping (Double) -> Void) async throws { throw ReconciliationFailure.assertion("Queue ran before explicit processing") }
    func createDirectory(path: String) async throws {}
    func delete(path: String) async throws {}
    func move(from sourcePath: String, to destinationPath: String) async throws {}
    func exists(path: String) async throws -> Bool { false }
}

func runDirectoryReconciliationRegressionTests() async throws {
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw ReconciliationFailure.assertion(message) }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reconciliation-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let local = root.appendingPathComponent("local")
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    let source = local.appendingPathComponent("new.txt")
    try Data("accepted snapshot".utf8).write(to: source)
    let queue = OfflineSyncQueue(queueURL: root.appendingPathComponent("queue.db"))
    let store = SyncMetadataStore(metadataURL: root.appendingPathComponent("metadata.db"), vaultId: "test")
    let service = SyncService(vaultId: "test", metadataStore: store, queue: queue, networkMonitor: ReconciliationNetwork(), automaticallyProcessesQueue: false, notifiesFileProvider: false)
    let storage = ReconciliationStorage()
    service.configure(storageClient: storage)
    let first = try await service.syncDirectory(directoryId: "/", localPath: local.path, remotePath: "/")
    try require(first.count == 1 && first[0].fileId == "/new.txt" && first[0].syncStatus == .pendingUpload, "Metadata must be committed as pending before execution")
    guard let queued = try queue.allItemsPersistent().first, case .upload(_, let staged, _) = queued.operation else { throw ReconciliationFailure.assertion("Missing immutable queued upload") }
    try Data("later edit".utf8).write(to: source)
    let accepted = try Data(contentsOf: URL(fileURLWithPath: staged))
    try require(accepted == Data("accepted snapshot".utf8), "Queued upload must not refer to mutable source bytes")
    try FileManager.default.removeItem(at: source)
    storage.resources = [StorageResource(path: "/new.txt", displayName: "new.txt", isDirectory: false, contentLength: 20, etag: "\"other\"")]
    _ = try await service.syncDirectory(directoryId: "/", localPath: local.path, remotePath: "/")
    try require(service.getMetadata(fileId: "/new.txt")?.localPath == staged && service.getMetadata(fileId: "/new.txt")?.syncStatus == .pendingUpload, "Cloud-only observation must preserve pending local edit")
    let excluded = local.appendingPathComponent("excluded.txt")
    try Data("keep local".utf8).write(to: excluded)
    try store.updateMetadataPersistent(FileMetadata(fileId: "/excluded.txt", name: "excluded.txt", parentId: "/", isDirectory: false, syncStatus: .localOnly, localPath: excluded.path, size: 10))
    _ = try await service.syncDirectory(directoryId: "/", localPath: local.path, remotePath: "/")
    try require(!queue.hasPendingOperation(fileId: "/excluded.txt") && service.getMetadata(fileId: "/excluded.txt")?.syncStatus == .localOnly, "An explicitly local-only file must not be uploaded")
    let baselineTime = Date(timeIntervalSince1970: 100)
    let edited = FileMetadata(fileId: "/old.txt", name: "old.txt", parentId: "/", isDirectory: false, syncStatus: .synced, size: 10, localModifiedAt: baselineTime.addingTimeInterval(10), etag: "\"old\"", lastSyncTime: baselineTime)
    let remote = StorageResource(path: "/old.txt", displayName: "old.txt", isDirectory: false, contentLength: 10, lastModified: baselineTime.addingTimeInterval(-10), etag: "\"new\"")
    try require(SyncService.reconciledStatus(local: edited, remote: remote) == .conflict, "ETag mismatch must detect concurrent change regardless of server clock")
    print("✅ Directory reconciliation: immutable uploads, pending preservation and ETag baseline passed")
}
