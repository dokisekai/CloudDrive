import Foundation
import FileProvider
import UniformTypeIdentifiers
import CloudDriveCore
import CloudDriveSupport

/// Resolves identifiers using VFS reads and pending local metadata.
struct FileProviderItemLookup {
    let vfs: VirtualFileSystem
    let syncManager: SyncManager
    let mapError: (VFSError) -> NSFileProviderError

    func find(identifier: String, in directoryId: String? = nil) throws -> VirtualFileItem {
        do {
            // 0. Try direct lookup by ID (for encrypted mode and direct ID queries)
            if let item = try? vfs.getItem(id: identifier) {
                return item
            }
            
            // If search directory is specified, search directly within it
            if let directoryId = directoryId {
                let items = try vfs.listDirectory(directoryId: directoryId)
                if let item = items.first(where: { $0.id == identifier }) {
                    return item
                }
            }
            
            // 1. Try lookup via parent directory (for direct mapping mode where identifier is path)
            if identifier.hasPrefix("/") {
                let parentPath = URL(fileURLWithPath: identifier).deletingLastPathComponent().path
                let parentId = (parentPath == "/" || parentPath.isEmpty) ? "ROOT" : parentPath
                if let parentItems = try? vfs.listDirectory(directoryId: parentId),
                   let item = parentItems.first(where: { $0.id == identifier }) {
                    return item
                }
            }
            
            // 2. Check root directory
            let rootItems = try vfs.listDirectory(directoryId: "ROOT")
            if let item = rootItems.first(where: { $0.id == identifier }) {
                return item
            }
            
            // 3. Fallback recursive search (depth limited to 3 to prevent network stall)
            func searchRecursively(in dirId: String, depth: Int = 0) -> VirtualFileItem? {
                guard depth < 3 else { return nil }
                guard let items = try? vfs.listDirectory(directoryId: dirId) else { return nil }
                if let found = items.first(where: { $0.id == identifier }) {
                    return found
                }
                for item in items where item.isDirectory {
                    if let found = searchRecursively(in: item.id, depth: depth + 1) {
                        return found
                    }
                }
                return nil
            }
            
            if let found = searchRecursively(in: "ROOT") {
                return found
            }
            
            // 4. Fallback: check SyncManager metadata (handles offline pending uploads/creates)
            let candidateMeta = syncManager.getMetadata(fileId: identifier)
                ?? (identifier.hasPrefix("/") ? syncManager.getMetadata(fileId: String(identifier.dropFirst())) : syncManager.getMetadata(fileId: "/\(identifier)"))
            
            if let meta = candidateMeta {
                return VirtualFileItem(
                    id: meta.fileId,
                    name: meta.name,
                    isDirectory: meta.isDirectory,
                    size: meta.size,
                    modifiedAt: meta.localModifiedAt ?? Date(),
                    parentId: meta.parentId,
                    syncStatus: meta.syncStatus,
                    remotePath: meta.remotePath
                )
            }
            
            // 5. Fallback: check ItemAliasStore for renamed/moved item transitions
            let resolvedId = ItemAliasStore.shared.resolve(identifier)
            if resolvedId != identifier {
                return try find(identifier: resolvedId, in: directoryId)
            }
            
            throw NSFileProviderError(.noSuchItem)
        } catch let error as VFSError {
            // Convert VFSError to NSFileProviderError
            throw mapError(error)
        } catch let error as NSFileProviderError {
            throw error
        } catch {
            // Convert generic error to NSFileProviderError
            throw NSFileProviderError(.noSuchItem)
        }
    }
}

extension FileProviderExtension {
    func findItem(identifier: String, in directoryId: String? = nil) throws -> VirtualFileItem {
        try FileProviderItemLookup(vfs: vfs, syncManager: syncManager, mapError: mapToFileProviderError).find(identifier: identifier, in: directoryId)
    }
}
