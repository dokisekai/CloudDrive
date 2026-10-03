import Foundation
import CloudDriveContracts
import CloudDriveSupport
import UniformTypeIdentifiers

extension LocalStorageClient {
    func makeETag(size: Int64, mtime: Date?) -> String {
        let ts = Int((mtime?.timeIntervalSince1970 ?? 0) * 1000)
        return "\"\(ts)-\(size)\""
    }

    func currentETag(atPath path: String) -> String? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = attrs[.modificationDate] as? Date
        return makeETag(size: size, mtime: mtime)
    }
}
