import Foundation
import FileProvider
import UniformTypeIdentifiers
import CloudDriveCore

extension FileProviderExtension {
    func handleCreateEmptyFile(itemTemplate: NSFileProviderItem, actualParentId: String, options: NSFileProviderCreateItemOptions, progress: Progress, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) async throws {
        if options.contains(.mayAlreadyExist), let existing = try vfs.listDirectory(directoryId: actualParentId).first(where: { $0.name == itemTemplate.filename }) {
            progress.completedUnitCount = 100
            completionHandler(makeItem(vfsItem: existing, isEncrypted: vfs.isEncrypted), [], false, nil)
            return
        }
        let staged = try PendingContentStager(vaultId: currentVaultIdentifier).stageEmpty(filename: itemTemplate.filename)
        let item = try acceptCreatedFile(itemTemplate: itemTemplate, parentId: actualParentId, staged: staged)
        progress.completedUnitCount = 100
        signalEnumeratorDebounced(for: itemTemplate.parentItemIdentifier)
        signalEnumeratorDebounced(for: .workingSet)
        completionHandler(item, [], false, nil)
    }
}
