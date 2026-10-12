import Foundation
import CloudDriveContracts

extension CacheService {
    public func matchingConfirmedSource(for incomingFileId: String) -> (fileId: String, etag: String)? {
        guard metadataStore.isHealthy,
              let incoming = try? contentIndex.get(incomingFileId),
              contentIndex.matches(incoming, url: storage.localPath(for: incomingFileId)),
              let candidates = try? contentIndex.candidates(hash: incoming.hash, size: incoming.size) else { return nil }
        for candidate in candidates where candidate.fileId != incoming.fileId {
            do {
                let metadata = try syncManager.getMetadataPersistent(fileId: candidate.fileId) ?? syncManager.getMetadataPersistent(fileId: "/" + candidate.fileId)
                guard let metadata, !metadata.isDirectory, metadata.syncStatus == .synced,
                      metadata.size == incoming.size,
                      metadata.localPath == storage.localPath(for: metadata.fileId).path,
                      let tag = try? StorageContentVerification.mutationETag(metadata.etag, required: true),
                      metadata.remoteETag == nil || metadata.remoteETag == tag,
                      contentIndex.matches(candidate, url: storage.localPath(for: metadata.fileId)),
                      !syncManager.hasPendingOperation(fileId: metadata.fileId) else { continue }
                let confirmed = candidate.etag == tag || (candidate.generation != nil && candidate.generation == metadata.localModifiedAt?.timeIntervalSince1970 && metadata.lastSyncTime.map { $0.timeIntervalSince1970 >= candidate.generation! } == true)
                if confirmed { return (metadata.fileId, tag) }
            } catch { continue }
        }
        return nil
    }

    /// Called only after publishing the immutable accepted creation snapshot.
    public func bindAcceptedGeneration(fileId: String, modifiedAt: Date) {
        try? withPublicationLease(fileId: fileId) {
            guard let entry = try contentIndex.get(fileId), contentIndex.matches(entry, url: storage.localPath(for: fileId)) else { return }
            try contentIndex.record(fileId: fileId, hash: entry.hash, etag: nil, generation: modifiedAt.timeIntervalSince1970, url: storage.localPath(for: fileId))
        }
    }
}
