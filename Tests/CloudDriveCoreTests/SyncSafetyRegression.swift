import Foundation
import CloudDriveCore
import CloudDriveVFS
import CloudDriveVaultFormat

private enum SafetyFailure: Error { case assertion(String) }
private final class SafetyStorage: StorageClient {
    var modes: [StorageWriteMode] = []
    var deletedTag: String?
    var deletedPaths: [String] = []
    var onDownload: (() throws -> Void)?
    func listDirectory(path: String) async throws -> [StorageResource] { [] }
    func uploadFile(localURL: URL, to remotePath: String, progress: @escaping (Double) -> Void) async throws { throw SafetyFailure.assertion("Unconditional upload") }
    func uploadFile(localURL: URL, to remotePath: String, mode: StorageWriteMode, progress: @escaping (Double) -> Void) async throws -> String? {
        modes.append(mode)
        throw StorageError.serverError(statusCode: 412, message: "Existing remote file")
    }
    func downloadFile(path: String, to destinationURL: URL, progress: @escaping (Double) -> Void) async throws {
        guard let onDownload else { throw StorageError.networkError("Offline") }
        try Data("remote version".utf8).write(to: destinationURL)
        try onDownload()
    }
    func createDirectory(path: String) async throws {}
    func delete(path: String) async throws { throw SafetyFailure.assertion("Unconditional delete") }
    func delete(path: String, expectedETag: String?) async throws { deletedTag = expectedETag; deletedPaths.append(path) }
    func move(from sourcePath: String, to destinationPath: String) async throws {}
    func exists(path: String) async throws -> Bool { true }
}

public func runSyncSafetyRegressionTests() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-safety-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = SafetyStorage()
    let queue = OfflineSyncQueue(queueURL: root.appendingPathComponent("queue.json"))
    let service = SyncService(vaultId: "safety", metadataStore: SyncMetadataStore(metadataURL: root.appendingPathComponent("metadata.json"), vaultId: "safety"), queue: queue, automaticallyProcessesQueue: false, notifiesFileProvider: false)
    service.configure(storageClient: storage)
    let local = root.appendingPathComponent("local")
    try Data("local edits".utf8).write(to: local)
    let meta = FileMetadata(fileId: "/file", name: "file", parentId: "/", isDirectory: false, syncStatus: .conflict, localPath: local.path, remotePath: "/file")
    try service.metadataStore.updateMetadataPersistent(meta)
    try service.enqueuePersistent(.upload(fileId: "/file", localPath: local.path, remotePath: "/file"))
    await service.processPendingOperations()
    guard storage.modes.count == 1, case .createIfAbsent = storage.modes[0], queue.getCount() == 1 else { throw SafetyFailure.assertion("New uploads must create conditionally and retain conflicts") }
    let originalId = queue.getAllItems()[0].id
    do {
        try await SyncConflictResolver().resolveConflict(fileId: "/file", strategy: .forkBothWithSuffix, storageClient: storage, vfs: nil, syncManager: SyncManager(service: service), cacheManager: CacheManager.forVault("safety"))
        throw SafetyFailure.assertion("Failed remote restoration must throw")
    } catch StorageError.networkError { }
    guard queue.getAllItems().contains(where: { $0.id == originalId }), try String(contentsOf: local, encoding: .utf8) == "local edits", service.getMetadata(fileId: "/file")?.syncStatus == .conflict else { throw SafetyFailure.assertion("Failed conflict resolution must retain original edit and operation") }
    // A concurrent edit during restoration owns both its metadata and cache bytes.
    let cache = CacheManager.forVault("safety")
    let cacheURL = cache.localPath(for: "/file")
    try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    storage.onDownload = {
        try Data("newest edit".utf8).write(to: cacheURL)
        var newer = meta
        newer.localPath = cacheURL.path
        newer.syncStatus = .pendingUpload
        try service.metadataStore.updateMetadataPersistent(newer)
        try service.enqueuePersistent(.upload(fileId: "/file", localPath: cacheURL.path, remotePath: "/file"))
    }
    try await SyncConflictResolver().resolveConflict(fileId: "/file", strategy: .remoteWins, storageClient: storage, vfs: nil, syncManager: SyncManager(service: service), cacheManager: cache)
    guard try String(contentsOf: cacheURL, encoding: .utf8) == "newest edit", service.getMetadata(fileId: "/file")?.localPath == cacheURL.path, service.getMetadata(fileId: "/file")?.syncStatus == .pendingUpload, queue.getAllItems().contains(where: { $0.operation.fileId == "/file" }) else { throw SafetyFailure.assertion("Restore must not publish old bytes over a concurrent edit") }
    storage.onDownload = nil

    // Existing pending metadata never authorizes a blind ciphertext overwrite.
    let key = try VFSEncryption().generateMasterKey(password: "test fixture").0
    let format = CryptomatorFormat(masterkey: key, storageClient: storage, basePath: "/vault")
    let (_, _, encryptedName, _) = try format.getFileRemotePath(name: "pending.txt", parentDirId: Data())
    try service.metadataStore.updateMetadataPersistent(FileMetadata(fileId: "file_" + encryptedName, name: "pending.txt", parentId: "ROOT", isDirectory: false, syncStatus: .pendingUpload, remotePath: "/ciphertext"))
    let database = VFSDatabase(vaultId: "safety", directory: root.appendingPathComponent("vfs"))
    let encrypted = EncryptedVFSProvider(vaultId: "safety", cryptomatorFormat: format, storageClient: storage, database: database, syncManager: SyncManager(service: service), cacheManager: cache)
    let modesBefore = storage.modes.count
    do {
        _ = try await encrypted.uploadFile(localURL: local, name: "pending.txt", parentId: "ROOT", expectedETag: nil)
        throw SafetyFailure.assertion("Existing ciphertext must conflict")
    } catch StorageError.serverError(let code, _) where code == 412 { }
    guard storage.modes.count > modesBefore, case .createIfAbsent = storage.modes.last! else { throw SafetyFailure.assertion("Encrypted pending uploads must create conditionally") }

    let vault = VirtualFileSystem()
    vault.configureStorage(client: storage)
    try await vault.deleteRemoteItem(remotePath: "/cipher/directory.c9r", directoryId: "directory-id", expectedETag: "\"baseline\"")
    guard storage.deletedPaths.last == "/cipher/directory.c9r", storage.deletedTag == "\"baseline\"" else { throw SafetyFailure.assertion("Directory deletion must send a single collection DELETE") }
    let deleteCount = storage.deletedPaths.count
    try await vault.deleteRemoteItem(remotePath: "/cipher/long.c9s/contents.c9r", directoryId: nil, expectedETag: "\"long-name-baseline\"")
    guard storage.deletedPaths.count == deleteCount + 1, storage.deletedPaths.last == "/cipher/long.c9s/contents.c9r", storage.deletedTag == "\"long-name-baseline\"" else { throw SafetyFailure.assertion("Long-name deletion must conditionally delete only ciphertext content, preserving its wrapper") }
    try await vault.deleteRemoteItem(remotePath: "/cipher/file.c9r", directoryId: nil, expectedETag: "\"ciphertext-baseline\"")
    guard storage.deletedTag == "\"ciphertext-baseline\"" else { throw SafetyFailure.assertion("Ciphertext deletion must carry its revision") }

    let deleteMeta = FileMetadata(fileId: "/delete", name: "delete", parentId: "/", isDirectory: false, syncStatus: .synced, remotePath: "/delete", etag: "\"baseline\"")
    try service.metadataStore.updateMetadataPersistent(deleteMeta)
    try service.enqueuePersistent(.delete(fileId: "/delete", remotePath: "/delete"))
    await service.processPendingOperations()
    guard storage.deletedTag == "\"baseline\"" else { throw SafetyFailure.assertion("Delete must carry original revision") }
}
