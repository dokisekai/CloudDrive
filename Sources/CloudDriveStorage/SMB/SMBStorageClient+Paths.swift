import Foundation
import CloudDriveContracts
import CloudDriveSupport
import NetFS
import UniformTypeIdentifiers
import CryptoKit

extension SMBStorageClient {
    func resolveMountURL(for remotePath: String) throws -> URL {
        let mountPath = try ensureMounted()
        var base = URL(fileURLWithPath: mountPath)
        
        let configSubpath = config.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !configSubpath.isEmpty {
            base = base.appendingPathComponent(configSubpath)
        }
        
        let cleanRemote = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if cleanRemote.isEmpty {
            return base
        }
        return base.appendingPathComponent(cleanRemote)
    }
}
