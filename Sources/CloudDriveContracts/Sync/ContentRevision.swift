import Foundation
import CryptoKit

/// Versions the bytes being delivered, distinguishing local edits from their remote baseline.
public enum ContentRevision {
    public static func token(metadata: FileMetadata?, remoteETag: String?, modifiedAt: Date?, size: Int64?) -> String {
        if let metadata, metadata.syncStatus.protectsLocalChanges,
           metadata.syncStatus != .pendingMove && metadata.syncStatus != .pendingDelete,
           metadata.syncStatus != .error || metadata.localModifiedAt.map({ $0 > (metadata.lastSyncTime ?? .distantPast) }) == true || (metadata.localPath != nil && metadata.etag == nil && metadata.remoteETag == nil) {
            let time = (metadata.localModifiedAt ?? modifiedAt)?.timeIntervalSince1970.bitPattern ?? 0
            let generation = digest("\(time):\(metadata.size):\(metadata.localPath ?? metadata.fileId)")
            return "local:\(generation)"
        }
        if let etag = metadata?.remoteETag ?? remoteETag ?? metadata?.etag, !etag.isEmpty { return tokenForETag(etag) }
        let time = modifiedAt?.timeIntervalSince1970.bitPattern ?? 0
        return "unverified:\(time):\(size ?? 0)"
    }

    public static func tokenForETag(_ etag: String) -> String {
        let token = "etag:\(etag)"
        return token.utf8.count <= 128 ? token : "etag-sha256:\(digest(etag))"
    }

    public static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
