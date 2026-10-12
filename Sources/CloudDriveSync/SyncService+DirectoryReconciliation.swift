import Foundation
import Darwin
import CloudDriveContracts
import CloudDriveSupport

extension SyncService {
    public func syncDirectory(directoryId: String, localPath: String, remotePath: String) async throws -> [FileMetadata] {
        guard let storageClient = getStorageClient() else { throw SyncError.storageNotConfigured }
        guard networkMonitor.isOnline else { throw SyncError.networkUnavailable }
        // Both snapshots must be complete before reconciliation can accept work.
        let remoteFiles = try await storageClient.listDirectory(path: remotePath)
        let localRoot = URL(fileURLWithPath: localPath)
        let localFiles = fileManager.fileExists(atPath: localPath)
            ? try fileManager.contentsOfDirectory(at: localRoot, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]) : []
        var remoteMap: [String: StorageResource] = [:]
        for resource in remoteFiles {
            let name = resource.displayName
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), remoteMap[name] == nil else {
                throw SyncError.operationFailed("Directory snapshot contains an invalid or duplicate child")
            }
            remoteMap[name] = resource
        }
        let localMap = Dictionary(uniqueKeysWithValues: localFiles.map { ($0.lastPathComponent, $0) })
        let prefix = remotePath == "/" ? "" : remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parent = remotePath.hasPrefix("/") ? "/" + prefix : prefix
        var reconciled: [FileMetadata] = []
        // Read current metadata after network suspension, under the same journal
        // lock as enqueue/completion. Never publish a stale whole-directory batch.
        try withJournalCommit {
            for name in Set(remoteMap.keys).union(localMap.keys).sorted() {
                let fileId = parent.isEmpty || parent == "/" ? "/" + name : parent + "/" + name
                let existing = try metadataStore.getMetadataPersistent(fileId: fileId)
                if let existing, queue.hasPendingOperation(fileId: fileId) || Self.protectDuringReconciliation(existing.syncStatus) {
                    reconciled.append(existing)
                    continue
                }
                let remote = remoteMap[name]
                let local = localMap[name]
                if let local {
                    let values = try local.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey])
                    guard values.isSymbolicLink != true else { throw SyncError.operationFailed("Refusing to synchronize a symbolic link") }
                    var metadata = FileMetadata(fileId: fileId, name: name, parentId: directoryId,
                        isDirectory: values.isDirectory == true, syncStatus: .localOnly,
                        localPath: local.path, remotePath: remote?.path,
                        size: Int64(values.fileSize ?? 0), localModifiedAt: values.contentModificationDate,
                        remoteModifiedAt: remote?.lastModified, etag: existing?.etag, remoteETag: remote?.etag,
                        lastSyncTime: existing?.lastSyncTime)
                    if let remote {
                        metadata.syncStatus = Self.reconciledStatus(local: metadata, remote: remote)
                        // Retain the downloaded baseline until bytes are refreshed.
                        if metadata.syncStatus == .pendingUpload && !metadata.isDirectory {
                            let staged = try stageReconciliationUpload(local)
                            metadata.localPath = staged.path
                            try acceptSavePersistent(metadata: metadata, operation: .upload(fileId: fileId, localPath: staged.path, remotePath: remote.path), expectedETag: existing?.etag) {}
                        } else { try metadataStore.updateMetadataPersistent(metadata) }
                    } else {
                        let operation: SyncOperation
                        if metadata.isDirectory {
                            operation = .createDirectory(directoryId: fileId, name: name, parentId: directoryId, remotePath: fileId)
                        } else {
                            let staged = try stageReconciliationUpload(local)
                            metadata.localPath = staged.path
                            operation = .upload(fileId: fileId, localPath: staged.path, remotePath: fileId)
                        }
                        metadata.syncStatus = .pendingUpload
                        // A missing remote object is always create-if-absent, even
                        // when historical metadata still carries an old validator.
                        metadata.etag = nil
                        try acceptSavePersistent(metadata: metadata, operation: operation) {}
                    }
                    reconciled.append(metadata)
                } else if let remote {
                    let metadata = FileMetadata(fileId: fileId, name: name, parentId: directoryId,
                        isDirectory: remote.isDirectory, syncStatus: .cloudOnly,
                        remotePath: remote.path, size: remote.contentLength,
                        remoteModifiedAt: remote.lastModified, etag: nil, remoteETag: remote.etag)
                    try metadataStore.updateMetadataPersistent(metadata)
                    reconciled.append(metadata)
                }
            }
        }
        processSyncQueue()
        return reconciled
    }

    static func protectDuringReconciliation(_ status: SyncStatus) -> Bool {
        switch status {
        case .synced, .cloudOnly: return false
        default: return true
        }
    }

    static func reconciledStatus(local: FileMetadata, remote: StorageResource) -> SyncStatus {
        guard local.isDirectory == remote.isDirectory else { return .conflict }
        let localChanged = local.lastSyncTime.map { time in local.localModifiedAt.map { $0 > time } ?? true } ?? true
        let remoteChanged: Bool
        if let baseline = local.etag, let revision = remote.etag { remoteChanged = baseline != revision }
        else { remoteChanged = local.lastSyncTime.map { time in remote.lastModified.map { $0 > time } ?? true } ?? true }
        if localChanged && remoteChanged { return .conflict }
        if localChanged { return .pendingUpload }
        if remoteChanged { return .cloudOnly }
        return local.size == remote.contentLength ? .synced : .conflict
    }

    private func stageReconciliationUpload(_ source: URL) throws -> URL {
        let directory = queue.persistenceURL.deletingLastPathComponent().appendingPathComponent("pending_uploads")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString)
        do {
            let before = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            if copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_CLONE)) != 0 {
                try fileManager.copyItem(at: source, to: destination)
            }
            let after = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else {
                throw SyncError.operationFailed("Local content changed while preparing upload")
            }
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            try handle.synchronize()
            let fd = open(directory.path, O_RDONLY)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return destination
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }
}
