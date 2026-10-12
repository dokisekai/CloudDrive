import Foundation
import Darwin
import CloudDriveContracts
import CloudDriveSupport
import CloudDriveSync
import CloudDriveCache

/// Local edits are copied from an immutable snapshot, never from stale cloud bytes.
enum VFSLocalCopy {
    static func prepare(sourceId: String, targetId: String, name: String, parentId: String,
                        remotePath: String, encrypted: Bool, vaultId: String,
                        sync: SyncManager, cache: CacheManager) throws -> VirtualFileItem {
        try sync.withJournalCommit {
            guard let sourceMetadata = try sync.getMetadataPersistent(fileId: sourceId) else { throw VFSError.fileNotFound }
            guard try sync.getMetadataPersistent(fileId: targetId) == nil, !sync.hasPendingOperation(fileId: targetId) else {
                throw StorageError.serverError(statusCode: 412, message: "Copy destination already exists locally")
            }
            let source: URL
            if let path = sourceMetadata.localPath, FileManager.default.fileExists(atPath: path) { source = URL(fileURLWithPath: path) }
            else if cache.isCached(fileId: sourceId) { source = cache.localPath(for: sourceId) }
            else { throw VFSError.fileNotFound }
            let directory = sync.queue.persistenceURL.deletingLastPathComponent().appendingPathComponent("pending_uploads")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let staged = directory.appendingPathComponent(UUID().uuidString)
            do {
                guard try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
                      try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw VFSError.fileNotFound }
                if copyfile(source.path, staged.path, nil, copyfile_flags_t(COPYFILE_CLONE)) != 0 {
                    try FileManager.default.copyItem(at: source, to: staged)
                }
                let handle = try FileHandle(forWritingTo: staged)
                defer { try? handle.close() }
                try handle.synchronize()
                let fd = open(directory.path, O_RDONLY)
                guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                defer { close(fd) }
                guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            } catch { try? FileManager.default.removeItem(at: staged); throw error }
            let size = Int64(try staged.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            let status: SyncStatus = sourceMetadata.syncStatus == .localOnly ? .localOnly : .pendingUpload
            let metadata = FileMetadata(fileId: targetId, name: name, parentId: parentId, isDirectory: false,
                syncStatus: status, localPath: staged.path, remotePath: remotePath, size: size,
                localModifiedAt: Date(), downloadProgress: 1)
            let operation: SyncOperation?
            if status == .localOnly { operation = nil }
            else if encrypted { operation = .encryptedUpload(fileId: targetId, fileName: name, parentId: parentId, localPath: staged.path, vaultId: vaultId) }
            else { operation = .upload(fileId: targetId, localPath: staged.path, remotePath: remotePath) }
            try sync.acceptSavePersistent(metadata: metadata, operation: operation, expectedETag: nil) {}
            // Clone known cache metadata without rereading/hashing large content.
            if source.standardizedFileURL == cache.localPath(for: sourceId).standardizedFileURL,
               cache.isCached(fileId: sourceId) {
                try? cache.cloneCache(from: sourceId, to: targetId)
                if cache.isCached(fileId: targetId) {
                    var cached = metadata
                    cached.localPath = cache.localPath(for: targetId).path
                    try sync.updateMetadataPersistent(cached)
                }
            }
            return VirtualFileItem(id: targetId, name: name, isDirectory: false, size: size,
                modifiedAt: metadata.localModifiedAt ?? Date(), parentId: parentId,
                syncStatus: status, localPath: metadata.localPath, remotePath: remotePath)
        }
    }
}
