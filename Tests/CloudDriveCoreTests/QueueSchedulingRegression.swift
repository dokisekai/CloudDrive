import Foundation
@testable import CloudDriveSync
import CloudDriveContracts
import CloudDrivePersistence
import SQLite3

private enum QueueSchedulingFailure: Error { case assertion(String) }

func runQueueSchedulingRegressionTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("queue-scheduling-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let queue = OfflineSyncQueue(queueURL: root.appendingPathComponent("queue.db"))
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw QueueSchedulingFailure.assertion(message) }
    }
    let parent = try queue.enqueuePersistent(.createDirectory(directoryId: "/folder", name: "folder", parentId: "/", remotePath: "/folder"))
    let child = try queue.enqueuePersistent(.upload(fileId: "/folder/report", localPath: "/tmp/report", remotePath: "/folder/report"))
    let sibling = try queue.enqueuePersistent(.upload(fileId: "/folder2/report", localPath: "/tmp/report", remotePath: "/folder2/report"))
    try queue.recordFailure(id: parent.id, message: "conflict", conflict: true, nextAttemptAt: nil)
    try require(try queue.nextReadyItem()?.id == sibling.id, "Failed directory must block its child without blocking similarly named siblings")
    try queue.removeItemsPersistent(ids: [sibling.id])
    try require(try queue.nextReadyItem() == nil, "Directory child must remain blocked after unrelated work completes")
    try queue.removeItemsPersistent(ids: [parent.id])
    try require(try queue.nextReadyItem()?.id == child.id, "Removing resolved predecessor must unblock child")
    _ = try queue.claimItem(id: child.id)
    try require(try queue.claimItem(id: child.id) == nil, "Claim must not take ownership of an already running operation")
    let reopened = OfflineSyncQueue(queueURL: root.appendingPathComponent("queue.db"))
    try reopened.resetAbandonedItems(olderThan: 0)
    try require(try reopened.nextReadyItem()?.id == child.id, "Restart must recover freshly interrupted operation")
    try queue.removeItemsPersistent(ids: [child.id])
    let original = try queue.enqueuePersistent(.upload(fileId: "/source", localPath: "/tmp/report", remotePath: "/source"))
    let move = try queue.enqueuePersistent(.move(itemId: "/destination", sourceRemotePath: "/source", targetRemotePath: "/destination"))
    try queue.recordFailure(id: original.id, message: "offline", conflict: false, nextAttemptAt: Date().addingTimeInterval(30))
    try require(try queue.nextReadyItem() == nil, "Move source must wait for the original upload retry")
    try queue.removeItemsPersistent(ids: [original.id])
    try require(try queue.nextReadyItem()?.id == move.id, "Move must become eligible after source completes")
    try queue.removeItemsPersistent(ids: [move.id])
    let uploadBeforeDelete = try queue.enqueuePersistent(.upload(fileId: "/delete-after-upload", localPath: "/tmp/report", remotePath: "/delete-after-upload"), expectedETag: "\"base\"")
    let deleteSuccessor = try queue.enqueuePersistent(.delete(fileId: "/delete-after-upload", remotePath: "/delete-after-upload"), expectedETag: "\"base\"")
    _ = try queue.completeItem(id: uploadBeforeDelete.id, fileId: uploadBeforeDelete.operation.fileId, etag: "\"uploaded\"")
    let deletions = try queue.itemsForFilePersistent(fileId: "/delete-after-upload")
    try require(deletions.first?.id == deleteSuccessor.id && deletions.first?.expectedETag == "\"uploaded\"", "Delete successor must condition on its own predecessor upload version")
    try queue.removeItemsPersistent(ids: [deleteSuccessor.id])
    let uploadBeforeMove = try queue.enqueuePersistent(.upload(fileId: "/move-source", localPath: "/tmp/report", remotePath: "/move-source"), expectedETag: "\"base\"")
    let renamedMove = try queue.enqueuePersistent(.move(itemId: "/move-target", sourceRemotePath: "/move-source", targetRemotePath: "/move-target"), expectedETag: "\"base\"")
    let successor = try queue.findMoveSuccessor(sourcePath: "/move-source", excludeId: uploadBeforeMove.id)
    try require(successor?.movedId == "/move-target", "Move with changed identity must be found by its source dependency")
    let movedItem = VirtualFileItem(id: "/move-target", name: "move-target", isDirectory: false, size: 0, modifiedAt: Date(), parentId: "/", syncStatus: .pendingMove, remotePath: "/move-target")
    _ = try queue.completeItem(id: uploadBeforeMove.id, fileId: "/move-source", etag: "\"uploaded\"", replacement: movedItem)
    let moves = try queue.itemsForFilePersistent(fileId: "/move-target")
    try require(moves.first?.id == renamedMove.id && moves.first?.expectedETag == "\"uploaded\"", "Move with changed identity must inherit the confirmed source upload version")
    try queue.removeItemsPersistent(ids: [renamedMove.id])
    let claimedUpload = try queue.enqueuePersistent(.upload(fileId: "/claimed", localPath: "/tmp/report", remotePath: "/claimed"))
    _ = try queue.claimItem(id: claimedUpload.id)
    let canceled = try queue.removeUnstartedItemsPersistent(ids: [claimedUpload.id])
    try require(canceled.isEmpty && queue.getCount() == 1, "Cancellation must retain a newly claimed upload and report no removed payload")
    try queue.removeItemsPersistent(ids: [claimedUpload.id])
    for index in 0..<1000 {
        _ = try queue.enqueuePersistent(.upload(fileId: "/bulk/\(index)", localPath: "/tmp/report", remotePath: "/bulk/\(index)"))
    }
    let start = Date()
    for _ in 0..<1000 {
        guard let item = try queue.nextReadyItem() else { throw QueueSchedulingFailure.assertion("Bulk drain lost work") }
        _ = try queue.completeItem(id: item.id, fileId: item.operation.fileId, etag: "\"v1\"")
    }
    try require(queue.getCount() == 0, "Bulk queue must drain completely")
    let normalDuration = Date().timeIntervalSince(start)
    try queue.conn.withTransaction {
        for index in 0..<10000 {
            let blocked = try queue.enqueuePersistent(.upload(fileId: "/failed/\(index)", localPath: "/tmp/report", remotePath: "/failed/\(index)"))
            try queue.recordFailure(id: blocked.id, message: "permanent", conflict: false, nextAttemptAt: nil, isPermanentFailure: true)
        }
        for index in 0..<1000 {
            _ = try queue.enqueuePersistent(.upload(fileId: "/ready/\(index)", localPath: "/tmp/report", remotePath: "/ready/\(index)"))
        }
    }
    let blockedStart = Date()
    for _ in 0..<1000 {
        guard let item = try queue.nextReadyItem() else { throw QueueSchedulingFailure.assertion("Failed heads stranded independent work") }
        _ = try queue.completeItem(id: item.id, fileId: item.operation.fileId, etag: "\"v1\"")
    }
    let remainingReady = try queue.nextReadyItem()
    try require(queue.getCount() == 10000 && remainingReady == nil, "Permanent failures must remain recoverable without consuming independent work")
    let blockedDuration = Date().timeIntervalSince(blockedStart)
    let dependencyQueue = OfflineSyncQueue(queueURL: root.appendingPathComponent("blocked-descendants.db"))
    let failedParent = try dependencyQueue.enqueuePersistent(.createDirectory(directoryId: "/blocked-parent", name: "blocked-parent", parentId: "/", remotePath: "/blocked-parent"))
    try dependencyQueue.recordFailure(id: failedParent.id, message: "directory failed", conflict: false, nextAttemptAt: nil, isPermanentFailure: true)
    try dependencyQueue.conn.withTransaction {
        for index in 0..<10000 {
            _ = try dependencyQueue.enqueuePersistent(.upload(fileId: "/blocked-parent/\(index)", localPath: "/tmp/report", remotePath: "/blocked-parent/\(index)"))
        }
        for index in 0..<1000 {
            _ = try dependencyQueue.enqueuePersistent(.upload(fileId: "/independent/\(index)", localPath: "/tmp/report", remotePath: "/independent/\(index)"))
        }
    }
    let dependencyStart = Date()
    for _ in 0..<1000 {
        guard let ready = try dependencyQueue.nextReadyItem() else { throw QueueSchedulingFailure.assertion("Blocked descendants stranded independent work") }
        _ = try dependencyQueue.completeItem(id: ready.id, fileId: ready.operation.fileId, etag: "\"v1\"")
    }
    try require(try dependencyQueue.nextReadyItem() == nil, "Failed parent must keep all descendants blocked")
    let dependencyDuration = Date().timeIntervalSince(dependencyStart)
    try dependencyQueue.removeItemsPersistent(ids: [failedParent.id])
    let reopenedDependencies = OfflineSyncQueue(queueURL: root.appendingPathComponent("blocked-descendants.db"))
    try require(try reopenedDependencies.nextReadyItem() != nil, "Completing parent must durably release descendants after reopening")
    print("✅ 10,000 blocked descendants + 1,000 independent-item drain passed (\(dependencyDuration) seconds)")
    let chainQueue = OfflineSyncQueue(queueURL: root.appendingPathComponent("same-file-chain.db"))
    let firstVersion = try chainQueue.enqueuePersistent(.upload(fileId: "/chain", localPath: "/tmp/report", remotePath: "/chain"))
    _ = try chainQueue.claimItem(id: firstVersion.id)
    let canceledVersion = try chainQueue.enqueuePersistent(.upload(fileId: "/chain", localPath: "/tmp/report", remotePath: "/chain"))
    let lastVersion = try chainQueue.enqueuePersistent(.upload(fileId: "/chain", localPath: "/tmp/report", remotePath: "/chain"))
    _ = try chainQueue.removeUnstartedItemsPersistent(ids: [canceledVersion.id])
    try require(try chainQueue.nextReadyItem() == nil, "Canceling a middle version must preserve its earlier active predecessor dependency")
    try chainQueue.removeItemsPersistent(ids: [firstVersion.id])
    try require(try chainQueue.nextReadyItem()?.id == lastVersion.id, "Completing the inherited predecessor must release the final version")
    try chainQueue.removeItemsPersistent(ids: [lastVersion.id])
    try chainQueue.conn.withTransaction {
        for _ in 0..<1000 {
            _ = try chainQueue.enqueuePersistent(.upload(fileId: "/chain", localPath: "/tmp/report", remotePath: "/chain"))
        }
    }
    let edgeCount = try SQLiteStatement(db: try chainQueue.conn.getHandle(), sql: "SELECT COUNT(*) FROM sync_queue_dependency_edges;")
    try require(edgeCount.step() == SQLITE_ROW && edgeCount.columnInt64(at: 0) == 999, "One thousand versions must use a linear dependency chain instead of half a million edges")
    let metadata = SyncMetadataStore(metadataURL: root.appendingPathComponent("metadata.db"))
    for id in ["/percent%/file", "/percent-other/file", "/under_score/file", "/underXscore/file"] {
        try metadata.updateMetadataPersistent(FileMetadata(fileId: id, name: "file", parentId: "/", isDirectory: false, syncStatus: .synced))
    }
    metadata.removeDirectoryMetadata(forDirectoryPrefix: "/percent%")
    metadata.removeDirectoryMetadata(forDirectoryPrefix: "/under_score")
    try require(metadata.getMetadata(fileId: "/percent%/file") == nil && metadata.getMetadata(fileId: "/under_score/file") == nil, "Literal directory prefixes must remove their own descendants")
    try require(metadata.getMetadata(fileId: "/percent-other/file") != nil && metadata.getMetadata(fileId: "/underXscore/file") != nil, "Percent and underscore must not act as deletion wildcards")
    print("✅ 10,000 failed heads + 1,000 ready-item drain passed (\(blockedDuration) seconds)")
    print("✅ Queue dependencies, restart recovery and 1,000-item drain passed (\(normalDuration) seconds)")
}
