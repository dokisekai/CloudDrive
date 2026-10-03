import Foundation
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
        return destination
    }

    func stageEmpty(filename: String) throws -> URL {
        let destination = try destination(filename: filename)
        try Data().write(to: destination)
        return destination
    }

    private func destination(filename: String) throws -> URL {
        let directory = CloudDrivePaths.vaultDirectory(for: vaultId).appendingPathComponent("pending_uploads")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(UUID().uuidString)_\(filename)")
    }
}
