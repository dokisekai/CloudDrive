import Foundation
import CloudDriveContracts
import CloudDriveSupport
import NetFS
import UniformTypeIdentifiers
import CryptoKit

extension SMBStorageClient {
    func makeETag(for url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let mtime = values.contentModificationDate else {
            return nil
        }
        let size = values.fileSize ?? 0
        let timestamp = mtime.timeIntervalSince1970
        let raw = "\(timestamp)-\(size)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}
