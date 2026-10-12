import Foundation
import CloudDriveContracts
import SQLite3

extension OfflineSyncQueue {
    public func updatePendingOperation(oldFileId: String, newFileId: String, newRemotePath: String, newName: String, newParentId: String, sourceRemotePath: String? = nil) {
        do {
            try checkMigrationIfNeeded()
            try conn.withTransaction {
                let items = try allItemsPersistent()
                var successors: [SyncQueueItem] = []
                var rewritten: [SyncQueueItem] = []
                var affectedFileIds: Set<String> = [oldFileId, newFileId]
                let oldPrefix = oldFileId.hasSuffix("/") ? oldFileId : oldFileId + "/"
                let newPrefix = newFileId.hasSuffix("/") ? newFileId : newFileId + "/"
                
                for item in items {
                    let fId = item.operation.fileId
                    if fId == oldFileId && item.startedAt != nil {
                        let source: String?
                        switch item.operation {
                        case .upload(_, _, let path): source = path
                        case .encryptedUpload: source = sourceRemotePath
                        default: source = nil
                        }
                        if let source {
                            successors.append(SyncQueueItem(operation: .move(itemId: newFileId, sourceRemotePath: source, targetRemotePath: newRemotePath)))
                            continue
                        }
                        if case .encryptedUpload = item.operation {
                            throw SyncError.operationFailed("A rename of an uploading encrypted file requires its original remote path")
                        }
                    }
                    var updated = item
                    if fId == oldFileId {
                        updated.operation = Self.rewrite(item.operation, oldId: oldFileId, newId: newFileId, remotePath: newRemotePath, name: newName, parentId: newParentId)
                        rewritten.append(updated)
                        affectedFileIds.insert(fId)
                    } else if fId.hasPrefix(oldPrefix) {
                        // Cascading update for descendants in directory move
                        let subSuffix = String(fId.dropFirst(oldPrefix.count))
                        let newChildId = newPrefix + subSuffix
                        let newChildRemotePath = (item.operation.remotePath != nil) ? (newPrefix + subSuffix) : newRemotePath
                        let childParent = (item.operation.parentId == oldFileId) ? newFileId : (item.operation.parentId.map { Self.replacePrefix($0, oldPrefix, newPrefix) } ?? newFileId)
                        updated.operation = Self.rewriteChild(item.operation, newId: newChildId, newRemotePath: newChildRemotePath, newParentId: childParent)
                        rewritten.append(updated)
                        affectedFileIds.insert(fId)
                    } else if item.operation.parentId == oldFileId {
                        updated.operation = Self.rewriteChild(item.operation, newId: fId, newRemotePath: item.operation.remotePath ?? newRemotePath, newParentId: newFileId)
                        rewritten.append(updated)
                        affectedFileIds.insert(fId)
                    }
                }
                try persistBatchItems(rewritten, affectedFileIds: affectedFileIds)
                for successor in successors {
                    try insertItemInternal(successor)
                }
            }
        } catch { log(error) }
    }

    static func rewrite(_ operation: SyncOperation, oldId: String, newId: String, remotePath: String, name: String, parentId: String) -> SyncOperation {
        guard operation.fileId == oldId else { return operation }
        switch operation {
        case .upload(_, let localPath, _): return .upload(fileId: newId, localPath: localPath, remotePath: remotePath)
        case .encryptedUpload(_, _, _, let localPath, let vaultId): return .encryptedUpload(fileId: newId, fileName: name, parentId: parentId, localPath: localPath, vaultId: vaultId)
        case .createDirectory: return .createDirectory(directoryId: newId, name: name, parentId: parentId, remotePath: remotePath)
        case .encryptedCreateDirectory(_, _, _, _, let vaultId): return .encryptedCreateDirectory(directoryId: newId, name: name, parentId: parentId, remotePath: remotePath, vaultId: vaultId)
        case .delete: return .delete(fileId: newId, remotePath: remotePath)
        case .deleteItem(_, _, let isDirectory, let directoryId, let vaultId): return .deleteItem(fileId: newId, remotePath: remotePath, isDirectory: isDirectory, directoryId: directoryId, vaultId: vaultId)
        case .move(_, let source, _): return .move(itemId: newId, sourceRemotePath: source, targetRemotePath: remotePath)
        case .download(_, _, let localPath): return .download(fileId: newId, remotePath: remotePath, localPath: localPath)
        }
    }

    static func replacePrefix(_ string: String, _ oldPrefix: String, _ newPrefix: String) -> String {
        if string.hasPrefix(oldPrefix) {
            return newPrefix + string.dropFirst(oldPrefix.count)
        }
        return string
    }

    static func rewriteChild(_ operation: SyncOperation, newId: String, newRemotePath: String, newParentId: String) -> SyncOperation {
        switch operation {
        case .upload(_, let localPath, _):
            return .upload(fileId: newId, localPath: localPath, remotePath: newRemotePath)
        case .encryptedUpload(_, let fileName, _, let localPath, let vaultId):
            return .encryptedUpload(fileId: newId, fileName: fileName, parentId: newParentId, localPath: localPath, vaultId: vaultId)
        case .createDirectory(_, let name, _, _):
            return .createDirectory(directoryId: newId, name: name, parentId: newParentId, remotePath: newRemotePath)
        case .encryptedCreateDirectory(_, let name, _, _, let vaultId):
            return .encryptedCreateDirectory(directoryId: newId, name: name, parentId: newParentId, remotePath: newRemotePath, vaultId: vaultId)
        case .delete:
            return .delete(fileId: newId, remotePath: newRemotePath)
        case .deleteItem(_, _, let isDirectory, let directoryId, let vaultId):
            return .deleteItem(fileId: newId, remotePath: newRemotePath, isDirectory: isDirectory, directoryId: directoryId, vaultId: vaultId)
        case .move(_, let source, _):
            return .move(itemId: newId, sourceRemotePath: source, targetRemotePath: newRemotePath)
        case .download(_, _, let localPath):
            return .download(fileId: newId, remotePath: newRemotePath, localPath: localPath)
        }
    }
}
