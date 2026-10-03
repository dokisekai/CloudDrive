import Foundation

public enum StorageWriteMode: Sendable, Equatable {
    /// Only create if target does not already exist on remote (WebDAV sends If-None-Match: *).
    /// Fails with 412 if target already exists.
    case createIfAbsent
    /// Only replace if remote target matches expected ETag (WebDAV sends If-Match: <etag>).
    /// Fails with 412 if remote target was modified.
    case replace(expectedETag: String)
    /// Unconditionally upload/overwrite. Only used when manually resolving conflicts.
    case forceOverwrite
}
