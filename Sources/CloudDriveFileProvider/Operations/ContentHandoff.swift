import Foundation
import FileProvider
import UniformTypeIdentifiers
import CloudDriveCore

/// Creates a disposable clone; the system must never own the primary cached content.
enum ContentHandoff {
    static func create(from sourceURL: URL, domain: NSFileProviderDomain) throws -> URL {
        let tempDir = (try? NSFileProviderManager(for: domain)?.temporaryDirectoryURL()) ?? FileManager.default.temporaryDirectory
        let handoffURL = tempDir.appendingPathComponent("handoff_\(UUID().uuidString)")
        if copyfile(sourceURL.path, handoffURL.path, nil, copyfile_flags_t(COPYFILE_CLONE)) != 0 {
            try FileManager.default.copyItem(at: sourceURL, to: handoffURL)
        }
        return handoffURL
    }
}
