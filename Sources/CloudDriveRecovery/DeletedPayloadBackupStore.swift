import Foundation
import CryptoKit
import Darwin

/// An independently durable recovery copy of an edit discarded by a delete.
public struct DeletedPayloadBackup: Codable, Identifiable, Sendable {
    public let id: String
    public let vaultId: String
    public let fileId: String
    public let name: String
    public let parentId: String
    public let remotePath: String?
    public let expectedETag: String?
    public let createdAt: Date
    public let size: Int64
    public let sha256: String
    public var exportedAt: Date?
}

/// Each backup has its own immutable payload and atomic manifest. Unexported
/// edits are never removed by automatic retention cleanup.
public final class DeletedPayloadBackupStore {
    private let directory: URL
    private let vaultId: String
    private let lock = NSLock()

    public init(vaultId: String, directory: URL? = nil) {
        self.vaultId = vaultId
        self.directory = directory ?? CloudDrivePaths.vaultDirectory(for: vaultId).appendingPathComponent("DeletedPayloads", isDirectory: true)
    }

    public func preserve(source: URL, fileId: String, name: String, parentId: String, remotePath: String?, expectedETag: String?) throws -> DeletedPayloadBackup {
        try withStoreLock {
            try prepareDirectory()
            let id = UUID().uuidString
            let payload = payloadURL(id)
            do {
                try copy(source, to: payload)
                let attributes = try FileManager.default.attributesOfItem(atPath: payload.path)
                let digest = try hash(payload)
                let backup = DeletedPayloadBackup(id: id, vaultId: vaultId, fileId: fileId, name: name, parentId: parentId, remotePath: remotePath, expectedETag: expectedETag, createdAt: Date(), size: (attributes[.size] as? NSNumber)?.int64Value ?? 0, sha256: digest, exportedAt: nil)
                try save(backup)
                return backup
            } catch {
                // A manifest is published only after its payload is durable.
                try? FileManager.default.removeItem(at: payload)
                try? FileManager.default.removeItem(at: manifestURL(id))
                throw error
            }
        }
    }

    public func list() throws -> [DeletedPayloadBackup] {
        try withStoreLock { try listUnlocked() }
    }

    public func payload(for id: String, verifyIntegrity: Bool = true) throws -> URL {
        try withStoreLock {
            let backup = try read(id)
            let url = payloadURL(backup.id)
            if verifyIntegrity, try hash(url) != backup.sha256 { throw CocoaError(.fileReadCorruptFile) }
            return url
        }
    }

    /// Export never overwrites an existing destination. Only a verified durable
    /// export starts the retention clock; a failed export keeps the backup.
    @discardableResult
    public func export(id: String, to destination: URL) throws -> DeletedPayloadBackup {
        try withStoreLock {
            var backup = try read(id)
            let source = payloadURL(backup.id)
            guard try hash(source) == backup.sha256 else { throw CocoaError(.fileReadCorruptFile) }
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporaryExport = destination.deletingLastPathComponent().appendingPathComponent(".deleted-payload-export-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporaryExport) }
            try copy(source, to: temporaryExport)
            guard try hash(temporaryExport) == backup.sha256 else { throw CocoaError(.fileReadCorruptFile) }
            // Publish only a fully copied file, atomically refusing a destination
            // created by another process between the initial check and this call.
            guard renamex_np(temporaryExport.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try synchronizeDirectory(destination.deletingLastPathComponent())
            backup.exportedAt = Date()
            try save(backup)
            return backup
        }
    }

    /// Explicitly discard an individual recovery copy after user review.
    public func discard(id: String) throws {
        try withStoreLock { try discardUnlocked(id) }
    }

    /// Default retention is 30 days after export; originals that have never
    /// been exported remain recoverable regardless of age.
    @discardableResult
    public func cleanupExported(olderThan cutoff: Date = Date().addingTimeInterval(-30 * 86400)) throws -> Int {
        try withStoreLock {
            let eligible = try listUnlocked().filter { $0.exportedAt.map { $0 < cutoff } ?? false }
            for backup in eligible { try discardUnlocked(backup.id) }
            return eligible.count
        }
    }

    private func withStoreLock<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            try Task.checkCancellation()
            try prepareDirectory()
            let fd = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { flock(fd, LOCK_UN) }
            try Task.checkCancellation()
            return try body()
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try synchronizeDirectory(directory.deletingLastPathComponent())
    }

    private func validID(_ id: String) throws {
        guard UUID(uuidString: id) != nil, !id.contains("/"), !id.contains("\\") else { throw CocoaError(.fileReadInvalidFileName) }
    }
    private func payloadURL(_ id: String) -> URL { directory.appendingPathComponent(id + ".payload") }
    private func manifestURL(_ id: String) -> URL { directory.appendingPathComponent(id + ".json") }
    private func read(_ id: String) throws -> DeletedPayloadBackup {
        try validID(id)
        let backup = try JSONDecoder().decode(DeletedPayloadBackup.self, from: Data(contentsOf: manifestURL(id)))
        guard backup.id == id, backup.vaultId == vaultId else { throw CocoaError(.fileReadCorruptFile) }
        return backup
    }
    private func listUnlocked() throws -> [DeletedPayloadBackup] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try read($0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.createdAt > $1.createdAt }
    }
    private func save(_ backup: DeletedPayloadBackup) throws {
        let url = manifestURL(backup.id)
        try JSONEncoder().encode(backup).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try synchronize(url)
        try synchronizeDirectory(directory)
    }
    private func discardUnlocked(_ id: String) throws {
        _ = try read(id)
        // Remove the manifest last: interruption leaves a visible recovery error,
        // never a falsely successful export or a silently missing record.
        if FileManager.default.fileExists(atPath: payloadURL(id).path) {
            try FileManager.default.removeItem(at: payloadURL(id))
        }
        try FileManager.default.removeItem(at: manifestURL(id))
        try synchronizeDirectory(directory)
    }
    private func copy(_ source: URL, to destination: URL, onCreated: () -> Void = {}) throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
        // copyItem refuses a preexisting destination, including a symlink.
        try FileManager.default.copyItem(at: source, to: destination)
        onCreated()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        try synchronize(destination)
        try synchronizeDirectory(destination.deletingLastPathComponent())
    }
    private func synchronize(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    private func synchronizeDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    private func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        try Task.checkCancellation()
        while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty {
            try Task.checkCancellation()
            hash.update(data: block)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
