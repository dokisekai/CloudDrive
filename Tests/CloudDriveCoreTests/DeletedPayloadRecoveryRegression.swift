import Foundation
import CloudDriveCore

private enum DeletedPayloadTestFailure: Error { case assertion(String) }

public func runDeletedPayloadRecoveryRegressionTests() throws {
    // Malformed caller ranges must return errors rather than integer traps;
    // alignment near Int.max must clamp safely to EOF.
    let aligned = try AlignedReadRange.calculate(location: 7, length: 10, alignment: 8, fileSize: 19)
    guard aligned.start == 0, aligned.end == 19 else { throw DeletedPayloadTestFailure.assertion("Range alignment must clamp to the file size") }
    let maximum = try AlignedReadRange.calculate(location: Int.max - 2, length: 2, alignment: 16, fileSize: Int64(Int.max))
    guard maximum.end == Int.max, maximum.start <= maximum.end else { throw DeletedPayloadTestFailure.assertion("Alignment must not overflow near Int.max") }
    for invalid in [(Int.max, 1), (-1, 1), (0, -1)] {
        do {
            _ = try AlignedReadRange.calculate(location: invalid.0, length: invalid.1, alignment: 4, fileSize: 100)
            throw DeletedPayloadTestFailure.assertion("Malformed ranges must be rejected")
        } catch StorageError.invalidOperation { }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeletedPayloadTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    let content = Data("unsynchronized encrypted-vault cleartext edit".utf8)
    try content.write(to: source)
    let directory = root.appendingPathComponent("backups")
    let first = DeletedPayloadBackupStore(vaultId: "test", directory: directory)
    let record = try first.preserve(source: source, fileId: "file_abc", name: "notes.txt", parentId: "ROOT", remotePath: "/encrypted/file.c9r", expectedETag: "\"baseline\"")
    // A fresh store instance recovers both identity and bytes independently of
    // the sync metadata row, queue completion and deletion of the source cache.
    try FileManager.default.removeItem(at: source)
    let reopened = DeletedPayloadBackupStore(vaultId: "test", directory: directory)
    let listed = try reopened.list()
    guard listed.count == 1, listed[0].id == record.id, listed[0].fileId == "file_abc", listed[0].expectedETag == "\"baseline\"", try Data(contentsOf: reopened.payload(for: record.id)) == content else { throw DeletedPayloadTestFailure.assertion("Recovery manifest and immutable edit must survive reopening") }
    guard try reopened.cleanupExported(olderThan: Date().addingTimeInterval(3600)) == 0 else { throw DeletedPayloadTestFailure.assertion("Unexported edits must never expire automatically") }
    let occupied = root.appendingPathComponent("occupied")
    try Data("keep".utf8).write(to: occupied)
    do {
        _ = try reopened.export(id: record.id, to: occupied)
        throw DeletedPayloadTestFailure.assertion("Export must not overwrite a destination")
    } catch CocoaError.fileWriteFileExists { }
    guard try Data(contentsOf: occupied) == Data("keep".utf8), try reopened.list()[0].exportedAt == nil else { throw DeletedPayloadTestFailure.assertion("Failed export must retain both destination and unexported backup") }
    let exported = root.appendingPathComponent("exported-notes.txt")
    let exportedRecord = try reopened.export(id: record.id, to: exported)
    guard exportedRecord.exportedAt != nil, try Data(contentsOf: exported) == content else { throw DeletedPayloadTestFailure.assertion("Successful export must verify the recovered bytes") }
    guard try reopened.cleanupExported(olderThan: Date().addingTimeInterval(3600)) == 1, try reopened.list().isEmpty, try Data(contentsOf: exported) == content else { throw DeletedPayloadTestFailure.assertion("Retention cleanup may remove an exported backup but never its exported result") }
    let second = try first.preserve(source: exported, fileId: "file_corrupt", name: "corrupt.txt", parentId: "ROOT", remotePath: nil, expectedETag: nil)
    let payload = try first.payload(for: second.id)
    try Data("tampered".utf8).write(to: payload)
    do {
        _ = try first.export(id: second.id, to: root.appendingPathComponent("corrupt-export"))
        throw DeletedPayloadTestFailure.assertion("Corrupt recovery bytes must never be reported as successfully exported")
    } catch CocoaError.fileReadCorruptFile { }
    guard try first.list()[0].exportedAt == nil else { throw DeletedPayloadTestFailure.assertion("Corrupt backups remain visible for recovery") }
    do {
        _ = try first.payload(for: "../../outside")
        throw DeletedPayloadTestFailure.assertion("Recovery identifiers cannot escape the backup directory")
    } catch CocoaError.fileReadInvalidFileName { }
}
