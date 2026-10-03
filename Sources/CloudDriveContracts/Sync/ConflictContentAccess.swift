import Foundation

/// Location access needed by explicit conflict resolution, without a cache dependency.
public protocol ConflictContentAccess {
    func localPath(for fileId: String) -> URL
}
