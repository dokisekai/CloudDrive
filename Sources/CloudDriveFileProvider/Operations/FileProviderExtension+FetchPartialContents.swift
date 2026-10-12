import Foundation
import FileProvider
import UniformTypeIdentifiers
import CloudDriveCore

extension FileProviderExtension {
    public func fetchPartialContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion,
        request: NSFileProviderRequest,
        minimalRange requestedRange: NSRange,
        aligningTo alignment: Int,
        options: NSFileProviderFetchContentsOptions = [],
        completionHandler: @escaping (URL?, NSFileProviderItem?, NSRange, NSFileProviderMaterializationFlags, (any Error)?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let task = Task { [weak self] in
            guard let self else { completionHandler(nil, nil, requestedRange, [], NSFileProviderError(.noSuchItem)); return }
            var temporaryOutput: URL?
            var delivered = false
            defer { if !delivered, let temporaryOutput { try? FileManager.default.removeItem(at: temporaryOutput) } }
            do {
                try Task.checkCancellation()
                try await ensureVaultUnlocked()
                let item = try findItem(identifier: itemIdentifier.rawValue)
                guard !item.isDirectory else { throw NSFileProviderError(.noSuchItem) }
                let effectiveId = item.id
                cacheManager.beginAccess(fileId: effectiveId)
                defer { cacheManager.endAccess(fileId: effectiveId) }
                let bounds = try AlignedReadRange.calculate(location: requestedRange.location, length: requestedRange.length, alignment: alignment, fileSize: item.size)
                let expected = requestedETag(requestedVersion, fileId: effectiveId, remoteETag: item.etag)
                let temporaryDirectory = (try? NSFileProviderManager(for: domain)?.temporaryDirectoryURL()) ?? FileManager.default.temporaryDirectory
                let output = temporaryDirectory.appendingPathComponent("partial-" + UUID().uuidString)
                temporaryOutput = output
                guard FileManager.default.createFile(atPath: output.path, contents: Data()) else { throw CocoaError(.fileWriteUnknown) }
                let writer = try FileHandle(forWritingTo: output)
                defer { try? writer.close() }
                // A sparse output and bounded chunks keep large caller ranges from
                // allocating the entire requested range as one Data object.
                try writer.truncate(atOffset: UInt64(bounds.end))
                let reader: FileHandle? = try syncManager.withJournalCommit {
                    try validateRequestedContentVersion(requestedVersion, item: item)
                    let metadata = syncManager.getMetadata(fileId: effectiveId)
                    let protectsEdit = metadata?.syncStatus.protectsLocalChanges == true
                    let source: URL?
                    if let path = metadata?.localPath, FileManager.default.fileExists(atPath: path), protectsEdit || metadata?.etag == item.etag {
                        source = URL(fileURLWithPath: path)
                    } else if cacheManager.isCached(fileId: effectiveId), protectsEdit || metadata?.etag == item.etag {
                        source = cacheManager.localPath(for: effectiveId)
                    } else { source = nil }
                    if let source { return try FileHandle(forReadingFrom: source) }
                    guard !protectsEdit, expected != nil else { throw NSFileProviderError(.versionNoLongerAvailable) }
                    return nil
                }
                defer { try? reader?.close() }
                var offset = bounds.start
                while offset < bounds.end {
                    try Task.checkCancellation()
                    let count = min(4 * 1024 * 1024, bounds.end - offset)
                    let bytes: Data
                    if let reader {
                        try reader.seek(toOffset: UInt64(offset))
                        bytes = try reader.read(upToCount: count) ?? Data()
                    } else {
                        bytes = try await vfs.readRange(fileId: effectiveId, range: Int64(offset)...Int64(offset + count - 1), expectedETag: expected)
                    }
                    guard bytes.count == count else { throw NSFileProviderError(.versionNoLongerAvailable) }
                    try writer.seek(toOffset: UInt64(offset))
                    try writer.write(contentsOf: bytes)
                    offset += count
                    progress.completedUnitCount = Int64(Double(offset - bounds.start) / Double(max(1, bounds.length)) * 100)
                }
                let completionItem: FileProviderItem = try syncManager.withJournalCommit {
                    let current = try self.findItem(identifier: effectiveId)
                    try self.validateRequestedContentVersion(requestedVersion, item: current)
                    if itemIdentifier.rawValue == effectiveId {
                        return self.makeItem(vfsItem: item, isEncrypted: self.vfs.isEncrypted)
                    }
                    return FileProviderItem(identifier: itemIdentifier, parentIdentifier: (item.parentId == "ROOT" || item.parentId == "/") ? .rootContainer : NSFileProviderItemIdentifier(item.parentId), filename: item.name, contentType: .data, capabilities: [.allowsReading, .allowsWriting, .allowsDeleting, .allowsTrashing, .allowsRenaming, .allowsReparenting], documentSize: item.size, contentModificationDate: item.modifiedAt, creationDate: item.modifiedAt, isEncrypted: self.vfs.isEncrypted, remoteETag: item.etag, cacheManager: self.cacheManager, syncManager: self.syncManager)
                }
                delivered = true
                progress.completedUnitCount = 100
                completionHandler(output, completionItem, NSRange(location: bounds.start, length: bounds.length), [], nil)
            } catch {
                let mapped: Error = isReadRevisionConflict(error) ? NSFileProviderError(.versionNoLongerAvailable) : error is CancellationError ? CocoaError(.userCancelled) : (error as? NSFileProviderError ?? mapToFileProviderError(error))
                completionHandler(nil, nil, requestedRange, [], mapped)
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }
}
