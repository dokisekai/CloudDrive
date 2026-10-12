import Foundation
@testable import CloudDriveSync
import CloudDriveContracts

private enum JournalRegressionFailure: Error { case interrupted, assertion(String) }

func runSyncCommitJournalRegressionTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-commit-journal-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    func service(_ name: String) -> SyncService {
        let directory = root.appendingPathComponent(name)
        return SyncService(vaultId: "journal", metadataStore: SyncMetadataStore(metadataURL: directory.appendingPathComponent("metadata.json"), vaultId: "journal"), queue: OfflineSyncQueue(queueURL: directory.appendingPathComponent("queue.json")), automaticallyProcessesQueue: false, notifiesFileProvider: false)
    }
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw JournalRegressionFailure.assertion(message) }
    }
    let original = FileMetadata(fileId: "/report", name: "report", parentId: "/", isDirectory: false, syncStatus: .synced, localPath: "/tmp/original", remotePath: "/report", etag: "\"base\"")
    for (name, point) in [("prepared", SyncService.JournalFaultPoint.enqueuePrepared), ("metadata-written", .enqueueMetadataWritten)] {
        let first = service(name)
        try first.metadataStore.updateMetadataPersistent(original)
        first.journalFaultInjector = { if $0 == point { throw JournalRegressionFailure.interrupted } }
        do {
            try first.enqueuePersistent(.upload(fileId: "/report", localPath: "/tmp/original", remotePath: "/report"), startProcessing: false)
            throw JournalRegressionFailure.assertion("Expected enqueue interruption")
        } catch JournalRegressionFailure.interrupted { }
        try require(first.queue.getCount() == 0 && (try first.queue.pendingCommitEntries()).count == 1, "Unaccepted enqueue must retain its recovery intent without runnable remote work")
        let reopened = service(name)
        try require(reopened.metadataStore.getMetadata(fileId: "/report")?.syncStatus == .synced && reopened.queue.getCount() == 0, "Reopen must roll back a prepared metadata change without uploading")
        try require(try reopened.queue.pendingCommitEntries().isEmpty, "Prepared recovery must be retired durably")
    }
    let first = service("newer-edit")
    try first.metadataStore.updateMetadataPersistent(original)
    first.journalFaultInjector = { if $0 == .enqueueMetadataWritten { throw JournalRegressionFailure.interrupted } }
    do { try first.enqueuePersistent(.upload(fileId: "/report", localPath: "/tmp/original", remotePath: "/report"), startProcessing: false) }
    catch JournalRegressionFailure.interrupted { }
    var newer = original
    newer.localPath = "/tmp/newer-edit"
    newer.localModifiedAt = Date()
    newer.syncStatus = .pendingUpload
    try first.metadataStore.updateMetadataPersistent(newer)
    let reopenedNewer = service("newer-edit")
    try require(reopenedNewer.metadataStore.getMetadata(fileId: "/report")?.localPath == newer.localPath, "Prepared rollback must not overwrite a newer FileProvider edit")

    for (name, point) in [("receipt-written", SyncService.JournalFaultPoint.completionReceiptWritten), ("completion-metadata-written", .completionMetadataWritten)] {
        let first = service(name)
        try first.metadataStore.updateMetadataPersistent(original)
        let staged = root.appendingPathComponent(name).appendingPathComponent("pending-payload")
        try Data("accepted content".utf8).write(to: staged)
        try first.enqueuePersistent(.upload(fileId: "/report", localPath: staged.path, remotePath: "/report"), startProcessing: false)
        guard let item = try first.queue.nextReadyItem(), let claimed = try first.queue.claimItem(id: item.id) else { throw JournalRegressionFailure.assertion("Missing queued upload") }
        first.journalFaultInjector = { if $0 == point { throw JournalRegressionFailure.interrupted } }
        do {
            _ = try first.withJournalCommit {
                try first.commitCompletedOperation(claimed, result: SyncService.QueueResult(etag: "\"remote-accepted\"", remotePath: "/report", stagedPath: staged.path))
            }
            throw JournalRegressionFailure.assertion("Expected completion interruption")
        } catch JournalRegressionFailure.interrupted { }
        try require(first.queue.getCount() == 1 && FileManager.default.fileExists(atPath: staged.path), "Interrupted local commit must retain queued work and payload")
        let reopened = service(name)
        try require(reopened.queue.getCount() == 0 && (try reopened.queue.pendingCommitEntries()).isEmpty, "Reopen must complete the saved remote receipt without another network mutation")
        try require(reopened.metadataStore.getMetadata(fileId: "/report")?.etag == "\"remote-accepted\"" && reopened.metadataStore.getMetadata(fileId: "/report")?.syncStatus == .cloudOnly, "Recovered metadata must confirm the remote version without claiming missing local bytes are downloaded")
        try require(!FileManager.default.fileExists(atPath: staged.path), "Payload cleanup must follow both durable commits")
    }
    let replacementService = service("missing-replacement-metadata")
    let provisional = try replacementService.queue.enqueuePersistent(.encryptedUpload(fileId: "pending-id", fileName: "new-report", parentId: "ROOT", localPath: "/tmp/payload", vaultId: "journal"))
    let confirmed = VirtualFileItem(id: "confirmed-id", name: "new-report", isDirectory: false, size: 123, modifiedAt: Date(), parentId: "ROOT", remotePath: "/encrypted-object", etag: "\"confirmed\"")
    replacementService.journalFaultInjector = { if $0 == .completionReceiptWritten { throw JournalRegressionFailure.interrupted } }
    do {
        _ = try replacementService.withJournalCommit { try replacementService.commitCompletedOperation(provisional, result: SyncService.QueueResult(etag: confirmed.etag, remotePath: confirmed.remotePath, replacement: confirmed)) }
    } catch JournalRegressionFailure.interrupted { }
    let replacementReopened = service("missing-replacement-metadata")
    try require(replacementReopened.metadataStore.getMetadata(fileId: confirmed.id)?.size == 123 && replacementReopened.queue.getCount() == 0, "Receipt must rebuild missing replacement metadata before removing accepted work")
    let deletionService = service("delete-metadata-recovery")
    try deletionService.metadataStore.updateMetadataPersistent(original)
    let deletion = try deletionService.queue.enqueuePersistent(.delete(fileId: "/report", remotePath: "/report"), expectedETag: original.etag)
    deletionService.journalFaultInjector = { if $0 == .completionReceiptWritten { throw JournalRegressionFailure.interrupted } }
    do {
        _ = try deletionService.withJournalCommit { try deletionService.commitCompletedOperation(deletion, result: SyncService.QueueResult(deleted: true)) }
    } catch JournalRegressionFailure.interrupted { }
    try require(deletionService.metadataStore.getMetadata(fileId: "/report") != nil, "Confirmed delete must persist its receipt before changing local metadata")
    let deletionReopened = service("delete-metadata-recovery")
    try require(deletionReopened.metadataStore.getMetadata(fileId: "/report") == nil && deletionReopened.queue.getCount() == 0, "Delete receipt must recover metadata removal together with queue completion")
    let referencedPayload = service("referenced-clean-payload")
    let retainedStage = root.appendingPathComponent("referenced-clean-payload").appendingPathComponent("pending_uploads/current")
    try FileManager.default.createDirectory(at: retainedStage.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("latest accepted bytes".utf8).write(to: retainedStage)
    var stageMetadata = original
    stageMetadata.localPath = retainedStage.path
    try referencedPayload.acceptSavePersistent(metadata: stageMetadata, operation: .upload(fileId: "/report", localPath: retainedStage.path, remotePath: "/report")) {}
    guard let stageOperation = try referencedPayload.queue.nextReadyItem() else { throw JournalRegressionFailure.assertion("Missing staged save") }
    _ = try referencedPayload.withJournalCommit {
        try referencedPayload.commitCompletedOperation(stageOperation, result: SyncService.QueueResult(etag: "\"current\"", remotePath: "/report", stagedPath: retainedStage.path), metadataFallback: stageMetadata)
    }
    try require(referencedPayload.queue.getCount() == 0 && referencedPayload.metadataStore.getMetadata(fileId: "/report")?.syncStatus == .synced && FileManager.default.fileExists(atPath: retainedStage.path), "Confirmed upload must retain staged bytes while clean metadata still references them")
    try require(try Data(contentsOf: retainedStage) == Data("latest accepted bytes".utf8), "Retained clean staging replica must contain the accepted version")
    print("✅ Prepared enqueue CAS rollback and confirmed completion crash recovery passed")
}
