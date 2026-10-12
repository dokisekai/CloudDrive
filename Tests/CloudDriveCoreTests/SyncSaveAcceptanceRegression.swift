import Foundation
@testable import CloudDriveSync
import CloudDriveContracts

private enum SaveAcceptanceFailure: Error { case stale, crash, assertion(String) }

func runSyncSaveAcceptanceRegressionTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-save-acceptance-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    func service(_ name: String) -> SyncService {
        SyncService(metadataStore: SyncMetadataStore(metadataURL: root.appendingPathComponent(name).appendingPathComponent("metadata.db")), queue: OfflineSyncQueue(queueURL: root.appendingPathComponent(name).appendingPathComponent("queue.db")), automaticallyProcessesQueue: false, notifiesFileProvider: false)
    }
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw SaveAcceptanceFailure.assertion(message) }
    }
    let original = FileMetadata(fileId: "/report", name: "report", parentId: "/", isDirectory: false, syncStatus: .synced, localPath: "generation-0", remotePath: "/report", etag: "\"base\"")
    let first = service("compare-and-swap")
    try first.metadataStore.updateMetadataPersistent(original)
    var next = original
    next.localPath = "generation-1"
    try first.acceptSavePersistent(metadata: next, operation: .upload(fileId: "/report", localPath: next.localPath!, remotePath: "/report"), expectedETag: original.etag) {
        guard try first.metadataStore.getMetadataPersistent(fileId: "/report")?.localPath == "generation-0" else { throw SaveAcceptanceFailure.stale }
    }
    var stale = original
    stale.localPath = "generation-stale"
    do {
        try first.acceptSavePersistent(metadata: stale, operation: .upload(fileId: "/report", localPath: stale.localPath!, remotePath: "/report")) {
            guard try first.metadataStore.getMetadataPersistent(fileId: "/report")?.localPath == "generation-0" else { throw SaveAcceptanceFailure.stale }
        }
        throw SaveAcceptanceFailure.assertion("Stale save was accepted")
    } catch SaveAcceptanceFailure.stale { }
    try require(first.queue.getCount() == 1 && first.metadataStore.getMetadata(fileId: "/report")?.localPath == "generation-1", "Rejected stale save must leave the accepted metadata and queued payload intact")

    let interrupted = service("save-crash")
    try interrupted.metadataStore.updateMetadataPersistent(original)
    interrupted.journalFaultInjector = { if $0 == .enqueueMetadataWritten { throw SaveAcceptanceFailure.crash } }
    do { try interrupted.acceptSavePersistent(metadata: next, operation: .upload(fileId: "/report", localPath: next.localPath!, remotePath: "/report")) {} }
    catch SaveAcceptanceFailure.crash { }
    let recovered = service("save-crash")
    try require(recovered.queue.getCount() == 0 && recovered.metadataStore.getMetadata(fileId: "/report")?.localPath == original.localPath, "Interrupted unaccepted save must restore the previous full metadata snapshot")
    let newFile = service("new-file-crash")
    newFile.journalFaultInjector = { if $0 == .enqueueMetadataWritten { throw SaveAcceptanceFailure.crash } }
    do { try newFile.acceptSavePersistent(metadata: next, operation: .upload(fileId: "/report", localPath: next.localPath!, remotePath: "/report")) {} }
    catch SaveAcceptanceFailure.crash { }
    let newFileRecovered = service("new-file-crash")
    try require(newFileRecovered.queue.getCount() == 0 && newFileRecovered.metadataStore.getMetadata(fileId: "/report") == nil, "Unaccepted newly created metadata must be removed by exact-snapshot recovery")

    let rejectedQueueWrite = service("queue-finalize-failure")
    try rejectedQueueWrite.metadataStore.updateMetadataPersistent(original)
    try rejectedQueueWrite.queue.conn.execute(sql: "CREATE TRIGGER reject_save BEFORE INSERT ON sync_queue BEGIN SELECT RAISE(ABORT, 'Injected queue acceptance failure'); END;")
    var queueWriteFailed = false
    do { try rejectedQueueWrite.acceptSavePersistent(metadata: next, operation: .upload(fileId: "/report", localPath: next.localPath!, remotePath: "/report")) {} }
    catch { queueWriteFailed = true }
    let remainingIntents = try rejectedQueueWrite.queue.pendingCommitEntries()
    try require(queueWriteFailed && rejectedQueueWrite.queue.getCount() == 0 && remainingIntents.isEmpty && rejectedQueueWrite.metadataStore.getMetadata(fileId: "/report")?.localPath == original.localPath, "A real queue acceptance failure must immediately roll back staged metadata instead of leaving a falsely accepted save")

    let lockService = service("reentrant")
    let samePathService = service("reentrant")
    var nested = 0
    try lockService.withJournalCommit {
        try lockService.withJournalCommit { nested += 1 }
        try samePathService.withJournalCommit { nested += 1 }
    }
    try require(nested == 2, "Same-thread scopes must reuse the outer lease across services with the same canonical path")
    do {
        try lockService.withJournalCommit { try samePathService.withJournalCommit { throw SaveAcceptanceFailure.stale } }
    } catch SaveAcceptanceFailure.stale { }
    try samePathService.withJournalCommit { nested += 1 }
    try require(nested == 3, "Throwing nested scope must clear ownership and release its outer lease")

    let raced = service("concurrent-generations")
    try raced.metadataStore.updateMetadataPersistent(original)
    let group = DispatchGroup()
    let counterLock = NSLock()
    var acceptedCount = 0
    var unexpected: Error?
    for generation in 0..<16 {
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            var proposal = original
            proposal.localPath = "winner-\(generation)"
            do {
                try raced.acceptSavePersistent(metadata: proposal, operation: .upload(fileId: "/report", localPath: proposal.localPath!, remotePath: "/report")) {
                    guard try raced.metadataStore.getMetadataPersistent(fileId: "/report")?.localPath == original.localPath else { throw SaveAcceptanceFailure.stale }
                }
                counterLock.lock(); acceptedCount += 1; counterLock.unlock()
            } catch SaveAcceptanceFailure.stale { }
            catch { counterLock.lock(); unexpected = error; counterLock.unlock() }
        }
    }
    guard group.wait(timeout: .now() + 15) == .success else { throw SaveAcceptanceFailure.assertion("Concurrent save lease deadlocked") }
    if let unexpected { throw unexpected }
    try require(acceptedCount == 1 && raced.queue.getCount() == 1, "Exactly one concurrent save may accept a shared original generation")
    print("✅ Atomic save generation CAS, crash rollback and same-path nested commit leases passed")
}
