import Foundation
import Darwin
import CloudDriveCore

/// Copies system-owned input into the vault's persistent upload area.
/// Queue and metadata commits stay in the caller, preserving their operation order.
struct PendingContentStager {
    let vaultId: String

    func stage(_ source: URL, filename: String) throws -> URL {
        let destination = try destination(filename: filename)
        try Task.checkCancellation()
        if copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_CLONE)) != 0 {
            try FileManager.default.copyItem(at: source, to: destination)
        }
        try makeDurable(destination)
        return destination
    }

    func stageEmpty(filename: String) throws -> URL {
        let destination = try destination(filename: filename)
        try Data().write(to: destination)
        try makeDurable(destination)
        return destination
    }

    private func makeDurable(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        // Flush the directory entry too: accepting the save must survive a restart.
        let fd = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func destination(filename: String) throws -> URL {
        let directory = CloudDrivePaths.vaultDirectory(for: vaultId).appendingPathComponent("pending_uploads")
        CloudDrivePaths.secureDirectory(at: directory)
        let ext = (filename as NSString).pathExtension
        let safeSuffix = ext.isEmpty ? "" : ".\(ext)"
        return directory.appendingPathComponent("\(UUID().uuidString)\(safeSuffix)")
    }
}
