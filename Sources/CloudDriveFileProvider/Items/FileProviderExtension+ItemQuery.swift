import Foundation
import FileProvider
import UniformTypeIdentifiers
import CloudDriveCore
import CloudDriveStorage

extension FileProviderExtension {
    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        logInfo(.fileOps, "📁 FileProvider: Request item identifier: \(identifier.rawValue)")
        let progress = Progress(totalUnitCount: 1)
        
        let task = Task { [weak self] in
            guard let self = self else {
                logWarning(.fileOps, "⚠️ FileProvider: Self is nil, aborting item request")
                completionHandler(nil, NSFileProviderError(.noSuchItem))
                progress.completedUnitCount = 1
                return
            }
            
            do {
                // Root directory - return directly, independent of VFS
                if identifier == .rootContainer {
                    logInfo(.fileOps, "📁 FileProvider: Returning root container item")
                    let item = makeItem(
                        identifier: .rootContainer,
                        parentIdentifier: .rootContainer,
                        filename: "CloudDrive",
                        contentType: .folder,
                        capabilities: [.allowsReading, .allowsAddingSubItems, .allowsContentEnumerating],
                        documentSize: nil,
                        contentModificationDate: Date(),
                        creationDate: Date(),
                        isEncrypted: self.vfs.isEncrypted
                    )
                    completionHandler(item, nil)
                    progress.completedUnitCount = 1
                    return
                }
                
                // Trash container - return valid container item to satisfy Finder and prevent -1005 errors
                if identifier == .trashContainer {
                    logInfo(.fileOps, "📁 FileProvider: Returning trash container item")
                    let item = makeItem(
                        identifier: .trashContainer,
                        parentIdentifier: .trashContainer,
                        filename: "Trash",
                        contentType: .folder,
                        capabilities: [.allowsReading, .allowsContentEnumerating],
                        documentSize: nil,
                        contentModificationDate: Date(),
                        creationDate: Date(),
                        isEncrypted: false
                    )
                    completionHandler(item, nil)
                    progress.completedUnitCount = 1
                    return
                }
                
                try await self.ensureVaultUnlocked()
                
                // Retrieve file info from VFS
                logInfo(.fileOps, "🔍 FileProvider: Looking up item with ID: \(identifier.rawValue)")
                let vfsItem = try self.findItem(identifier: identifier.rawValue)
                let item = makeItem(vfsItem: vfsItem, isEncrypted: self.vfs.isEncrypted)
                logSuccess(.fileOps, "✅ FileProvider: Found item: \(item.filename)")
                completionHandler(item, nil)
                progress.completedUnitCount = 1
                
            } catch let error as VFSError {
                logError(.fileOps, "❌ FileProvider: VFSError while getting item \(identifier.rawValue): \(error)")
                let fpError = mapToFileProviderError(error)
                completionHandler(nil, fpError)
                progress.completedUnitCount = 1
            } catch let error as NSFileProviderError {
                logError(.fileOps, "❌ FileProvider: NSFileProviderError while getting item \(identifier.rawValue): \(error)")
                completionHandler(nil, error)
                progress.completedUnitCount = 1
            } catch {
                logError(.fileOps, "❌ FileProvider: Unknown error while getting item \(identifier.rawValue): \(error)")
                completionHandler(nil, NSFileProviderError(.noSuchItem))
                progress.completedUnitCount = 1
            }
        }
        
        progress.cancellationHandler = { task.cancel() }
        return progress
    }
    

}
