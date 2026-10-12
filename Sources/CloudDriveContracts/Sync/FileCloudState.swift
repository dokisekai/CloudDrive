import Foundation

/// A single immutable view of content availability and transfer state.
/// A status name alone never proves that bytes exist on this device.
public struct FileCloudState: Equatable, Sendable {
    public let isUploaded: Bool
    public let isUploading: Bool
    public let isDownloaded: Bool
    public let isDownloading: Bool
    public let isMostRecentVersionDownloaded: Bool
    public let isPending: Bool
    public let hasUploadError: Bool
    public let hasDownloadError: Bool
    public let downloadProgress: Double

    public init(metadata: FileMetadata?, remoteETag: String?, hasLocalBytes: Bool,
                isDirectory: Bool, isExcluded: Bool, metadataAvailable: Bool = true) {
        let status = metadata?.syncStatus
        let errorHasLocalEdits = status == .error && (
            metadata?.localModifiedAt.map { $0 > (metadata?.lastSyncTime ?? .distantPast) } == true ||
            (hasLocalBytes && metadata?.localPath != nil && metadata?.etag == nil && metadata?.remoteETag == nil))
        let dirtyContent = status == .pendingUpload || status == .uploading || status == .partialUpload || status == .localOnly || status == .conflict || errorHasLocalEdits
        let baseline = metadata?.etag?.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = (metadata?.remoteETag ?? remoteETag)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchesRemote: Bool
        if let current, !current.isEmpty {
            matchesRemote = baseline == current
        } else {
            matchesRemote = baseline?.isEmpty == false || metadata?.lastSyncTime != nil
        }
        let bytesAreCurrent = hasLocalBytes && (isExcluded || dirtyContent || matchesRemote)
        isDownloaded = isDirectory || hasLocalBytes
        isMostRecentVersionDownloaded = isDirectory || bytesAreCurrent
        isUploading = !isExcluded && status == .uploading
        isDownloading = !isDirectory && !isExcluded && !bytesAreCurrent && status == .downloading
        isPending = !isExcluded && (status == .pendingUpload || status == .partialUpload || status == .partialDownload || status == .pendingMove || status == .pendingDelete)
        if isExcluded {
            isUploaded = true
        } else if !metadataAvailable {
            isUploaded = false
        } else {
            switch status {
            case .pendingUpload, .uploading, .partialUpload, .conflict, .temporary:
                isUploaded = false
            case .error:
                isUploaded = !dirtyContent && (current?.isEmpty == false || baseline?.isEmpty == false || metadata?.lastSyncTime != nil)
            case .localOnly:
                isUploaded = false
            case .synced, .cloudOnly, .downloading, .partialDownload, .pendingMove, .pendingDelete:
                isUploaded = true
            case .verifying, .locked:
                isUploaded = baseline?.isEmpty == false || metadata?.lastSyncTime != nil
            case nil:
                isUploaded = true // Remote enumerated item, not an accepted local creation.
            }
        }
        let error = status == .error || status == .conflict || !metadataAvailable
        hasUploadError = error && !isUploaded
        hasDownloadError = error && !isMostRecentVersionDownloaded && !dirtyContent
        let progress = metadata?.downloadProgress ?? 0
        downloadProgress = isMostRecentVersionDownloaded ? 1 : (isDownloading && progress.isFinite ? min(1, max(0, progress)) : 0)
    }
}
