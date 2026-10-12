import Foundation
import FileProvider
import UniformTypeIdentifiers
import CloudDriveCore

extension FileProviderExtension {
    func createItem(basedOn itemTemplate: NSFileProviderItem,
                   fields: NSFileProviderItemFields,
                   contents url: URL?,
                   options: NSFileProviderCreateItemOptions = [],
                   request: NSFileProviderRequest,
                   completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
       
       logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
       logInfo(.fileOps, "📁 Starting createItem")
       logInfo(.fileOps, "Item name: \(itemTemplate.filename)")
       logInfo(.fileOps, "Item type: \(itemTemplate.contentType == .folder ? "directory" : "file")")
       logInfo(.fileOps, "Parent item ID: \(itemTemplate.parentItemIdentifier.rawValue)")
       logInfo(.fileOps, "Options: \(options)")
       logInfo(.fileOps, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
       
       let progress = Progress(totalUnitCount: 100)
       
       let task = Task { [weak self] in
           guard let self = self else {
               logError(.fileOps, "createItem failed: self is nil")
               completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
               return
           }
           
           do {
               try Task.checkCancellation()
               try await self.ensureVaultUnlocked()
               let parentId = itemTemplate.parentItemIdentifier.rawValue
               let actualParentId: String
               if parentId == NSFileProviderItemIdentifier.rootContainer.rawValue {
                   actualParentId = "ROOT"
               } else if self.vfs.isEncrypted {
                   // In encrypted mode, ID does not require leading slash
                   actualParentId = parentId
               } else {
                   // Ensure subdirectory ID is in full path format (prefixed with /)
                   actualParentId = parentId.hasPrefix("/") ? parentId : "/\(parentId)"
               }
               
               logInfo(.fileOps, "📁 FileProvider.createItem: Starting createItem")
               logInfo(.fileOps, "   Filename: \(itemTemplate.filename)")
               logInfo(.fileOps, "   Item type: \(itemTemplate.contentType == .folder ? "directory" : "file")")
               logInfo(.fileOps, "   Original parentId: \(parentId)")
               logInfo(.fileOps, "   Actual parentId: \(actualParentId)")
               logInfo(.fileOps, "   Root container ID: \(NSFileProviderItemIdentifier.rootContainer.rawValue)")
               logInfo(.fileOps, "   Is root container: \(parentId == NSFileProviderItemIdentifier.rootContainer.rawValue)")
               
               logInfo(.fileOps, "🔍 Path validation:")
               logInfo(.fileOps, "   Original parentId: '\(parentId)'")
               logInfo(.fileOps, "   Processed parentId: '\(actualParentId)'")
               logInfo(.fileOps, "   Is root directory: \(actualParentId == "ROOT")")
               logInfo(.fileOps, "   Path format check: \(actualParentId.hasPrefix("/") || actualParentId == "ROOT" ? "✅" : "❌")")
               
               // Check for filename collision in target directory unless mayAlreadyExist option is set
               if !options.contains(.mayAlreadyExist) {
                   if let existingChildren = try? self.vfs.listDirectory(directoryId: actualParentId) {
                       if existingChildren.contains(where: { $0.name.localizedCaseInsensitiveCompare(itemTemplate.filename) == .orderedSame }) {
                           logWarning(.fileOps, "⚠️ FileProvider.createItem: Filename collision detected: \(itemTemplate.filename) in \(actualParentId)")
                           throw NSFileProviderError(.filenameCollision)
                       }
                   }
               }
               
               if itemTemplate.contentType == .folder {
                   try await handleCreateDirectory(itemTemplate: itemTemplate, actualParentId: actualParentId, progress: progress, completionHandler: completionHandler)
               } else if let url = url {
                   try await handleCreateContentFile(itemTemplate: itemTemplate, actualParentId: actualParentId, url: url, progress: progress, completionHandler: completionHandler)
               } else if itemTemplate.contentType != .folder && url == nil {
                   try await handleCreateEmptyFile(itemTemplate: itemTemplate, actualParentId: actualParentId, options: options, progress: progress, completionHandler: completionHandler)
               } else {
                   throw NSFileProviderError(.noSuchItem)
               }
               
           } catch is CancellationError {
               completionHandler(nil, [], false, CocoaError(.userCancelled))
           } catch let error as VFSError {
               logError(.fileOps, "❌ FileProvider: VFSError in createItem: \(error)")
               let fpError = mapToFileProviderError(error)
               progress.completedUnitCount = 100
               completionHandler(nil, [], false, fpError)
           } catch let error as NSFileProviderError {
               logError(.fileOps, "❌ FileProvider: NSFileProviderError in createItem: \(error)")
               progress.completedUnitCount = 100
               completionHandler(nil, [], false, error)
           } catch {
               logError(.fileOps, "❌ FileProvider: Unknown error in createItem: \(error)")
               let fpError = mapToFileProviderError(error)
               progress.completedUnitCount = 100
               completionHandler(nil, [], false, fpError)
           }
       }
        progress.cancellationHandler = { task.cancel() }
    return progress
   }
}
