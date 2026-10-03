import Foundation
import CloudDriveContracts
import CloudDriveSupport
import Darwin

/// A disk transaction, shared by the app and its File Provider processes.
/// Atomic replacement protects readers; flock protects read-modify-write operations.
final class SyncFileStore<Value: Codable>: @unchecked Sendable {
    let url: URL
    private let initialValue: Value
    private let localLock = NSLock()

    init(url: URL, initialValue: Value) {
        self.url = url
        self.initialValue = initialValue
    }

    func read() throws -> Value {
        try transaction(write: false) { $0 }
    }

    @discardableResult
    func update<Result>(_ mutation: (inout Value) throws -> Result) throws -> Result {
        try transaction(write: true, mutation)
    }

    private func transaction<Result>(write: Bool, _ action: (inout Value) throws -> Result) throws -> Result {
        localLock.lock()
        defer { localLock.unlock() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lease = try SyncFileLease(url: url.appendingPathExtension("lock"), nonBlocking: false, shared: !write)
        defer { lease?.release() }
        var value = initialValue
        if FileManager.default.fileExists(atPath: url.path) {
            // A corrupt journal is an error, never an empty queue to overwrite.
            value = try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
        }
        let result = try action(&value)
        if write {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
        }
        return result
    }
}

/// The consumer keeps this separate lock open across network awaits.
/// The OS releases it when a process exits, so no stale lease needs recovery.
final class SyncFileLease: @unchecked Sendable {
    private var descriptor: Int32
    private let lock = NSLock()

    init?(url: URL, nonBlocking: Bool, shared: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Self.ioError("open sync lock") }
        let mode = (shared ? LOCK_SH : LOCK_EX) | (nonBlocking ? LOCK_NB : 0)
        var result: Int32
        repeat { result = flock(fd, mode) } while result != 0 && errno == EINTR
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            if nonBlocking && (code == EWOULDBLOCK || code == EAGAIN) { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Cannot acquire sync lock"])
        }
        descriptor = fd
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { release() }

    private static func ioError(_ operation: String) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: operation])
    }
}

enum SyncStoragePaths {
    static func directory(for vaultId: String?) -> URL {
        guard let vaultId else { return CloudDrivePaths.sharedDirectory }
        return CloudDrivePaths.vaultDirectory(for: vaultId)
    }
}
