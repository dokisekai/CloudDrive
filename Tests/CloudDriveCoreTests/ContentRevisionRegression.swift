import Foundation
import CloudDriveCore

func runContentRevisionRegressionTests() throws {
    var metadata = FileMetadata(fileId: "/file", name: "file", parentId: "/", isDirectory: false, syncStatus: .pendingUpload, localPath: "/pending/generation-a", size: 4, localModifiedAt: Date(timeIntervalSince1970: 100.1), etag: "\"baseline\"")
    func token() -> String { ContentRevision.token(metadata: metadata, remoteETag: "\"baseline\"", modifiedAt: Date(timeIntervalSince1970: 100), size: 4) }
    let first = token()
    metadata.localModifiedAt = Date(timeIntervalSince1970: 100.2)
    let second = token()
    metadata.localPath = "/pending/generation-b"
    let third = token()
    guard first.hasPrefix("local:"), first != second, second != third else { throw StorageError.invalidOperation }
    metadata.syncStatus = .synced
    metadata.etag = "\"confirmed\""
    metadata.remoteETag = "\"confirmed\""
    guard token() == "etag:\"confirmed\"" else { throw StorageError.invalidOperation }
    metadata.syncStatus = .pendingMove
    guard token() == "etag:\"confirmed\"" else { throw StorageError.invalidOperation }
    metadata.syncStatus = .pendingUpload
    metadata.localPath = String(repeating: "long-generation-path/", count: 100)
    guard token().utf8.count <= 128 else { throw StorageError.invalidOperation }
    metadata.syncStatus = .synced
    metadata.remoteETag = "\"" + String(repeating: "a", count: 300) + "\""
    guard token().utf8.count <= 128 && token().hasPrefix("etag-sha256:") else { throw StorageError.invalidOperation }
    let aligned = try AlignedReadRange.calculate(location: 7, length: 4, alignment: 4, fileSize: 10)
    guard aligned.start == 4, aligned.end == 10 else { throw StorageError.invalidOperation }
    let empty = try AlignedReadRange.calculate(location: 30, length: 0, alignment: 4, fileSize: 10)
    guard empty.start == 10, empty.length == 0 else { throw StorageError.invalidOperation }
    for invalid in [(Int.max, 1), (-1, 4), (0, -1)] {
        do {
            _ = try AlignedReadRange.calculate(location: invalid.0, length: invalid.1, alignment: 4, fileSize: 10)
            throw ContentRangeRegressionFailure.acceptedInvalidRange
        } catch StorageError.invalidOperation { }
    }
    let hugeAlignment = try AlignedReadRange.calculate(location: 0, length: 10, alignment: Int.max, fileSize: 10)
    guard hugeAlignment.start == 0, hugeAlignment.end == 10 else { throw StorageError.invalidOperation }
    print("✅ Local edit versions distinguish generations and subsecond edits from remote baseline")
}

private enum ContentRangeRegressionFailure: Error { case acceptedInvalidRange }
