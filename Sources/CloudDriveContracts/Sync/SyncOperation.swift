import Foundation

public enum SyncOperation: Codable {
    case upload(fileId: String, localPath: String, remotePath: String)
    case download(fileId: String, remotePath: String, localPath: String)
    case delete(fileId: String, remotePath: String)
    case createDirectory(directoryId: String, name: String, parentId: String, remotePath: String)
    case encryptedUpload(fileId: String, fileName: String, parentId: String, localPath: String, vaultId: String)
    case move(itemId: String, sourceRemotePath: String, targetRemotePath: String)
    case encryptedCreateDirectory(directoryId: String, name: String, parentId: String, remotePath: String, vaultId: String)
    case deleteItem(fileId: String, remotePath: String, isDirectory: Bool, directoryId: String?, vaultId: String)
    
    /// File ID associated with the operation
    public var fileId: String {
        switch self {
        case .upload(let fileId, _, _):
            return fileId
        case .download(let fileId, _, _):
            return fileId
        case .delete(let fileId, _):
            return fileId
        case .createDirectory(let directoryId, _, _, _):
            return directoryId
        case .encryptedUpload(let fileId, _, _, _, _):
            return fileId
        case .move(let itemId, _, _):
            return itemId
        case .encryptedCreateDirectory(let directoryId, _, _, _, _):
            return directoryId
        case .deleteItem(let fileId, _, _, _, _):
            return fileId
        }
    }
    
    /// Vault ID associated with the operation (if available)
    public var vaultId: String? {
        switch self {
        case .encryptedUpload(_, _, _, _, let vaultId):
            return vaultId
        case .encryptedCreateDirectory(_, _, _, _, let vaultId):
            return vaultId
        case .deleteItem(_, _, _, _, let vaultId):
            return vaultId
        default:
            return nil
        }
    }
    
    /// Target remote path associated with the operation (if applicable)
    public var remotePath: String? {
        switch self {
        case .upload(_, _, let path): return path
        case .download(_, let path, _): return path
        case .delete(_, let path): return path
        case .createDirectory(_, _, _, let path): return path
        case .encryptedCreateDirectory(_, _, _, let path, _): return path
        case .deleteItem(_, let path, _, _, _): return path
        case .move(_, _, let path): return path
        case .encryptedUpload: return nil
        }
    }

    /// Target parent ID associated with the operation (if applicable)
    public var parentId: String? {
        switch self {
        case .createDirectory(_, _, let parentId, _): return parentId
        case .encryptedUpload(_, _, let parentId, _, _): return parentId
        case .encryptedCreateDirectory(_, _, let parentId, _, _): return parentId
        default: return nil
        }
    }
    
    /// Operation description
    public var description: String {
        switch self {
        case .upload:
            return "Upload"
        case .download:
            return "Download"
        case .delete:
            return "Delete"
        case .createDirectory:
            return "Create Directory"
        case .encryptedUpload:
            return "Encrypted Upload"
        case .move:
            return "Move"
        case .encryptedCreateDirectory:
            return "Create Encrypted Directory"
        case .deleteItem:
            return "Delete Item"
        }
    }
}

// MARK: - 同步队列项

/// 同步队列中的项目
