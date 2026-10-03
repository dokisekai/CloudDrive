import Foundation
import FileProvider
import UniformTypeIdentifiers
import CloudDriveCore
import CloudDriveStorage

extension FileProviderExtension {
    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                   request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        logInfo(.fileOps, "📁 FileProvider: Creating enumerator")
        logInfo(.fileOps, "Container item ID: \(containerItemIdentifier.rawValue)")
        return FileProviderEnumerator(
            enumeratedItemIdentifier: containerItemIdentifier,
            vfs: vfs,
            extensionRef: self
        )
    }
}
