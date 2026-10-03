import Foundation
import CryptomatorCryptoLib

extension VirtualFileSystem {
    public func recordOfflineFile(id: String, name: String, parentId: String, size: Int64, remotePath: String) {
        try? database.insertFile(
            id: id,
            name: name,
            parentId: parentId,
            size: size,
            encryptedName: name,
            remotePath: remotePath
        )
    }

    public func recordOfflineDirectory(id: String, name: String, parentId: String, remotePath: String) {
        try? database.insertDirectory(
            id: id,
            name: name,
            parentId: parentId,
            encryptedId: name,
            remotePath: remotePath
        )
    }

    public func deleteFromLocalDatabaseOnly(itemId: String) {
        if let f = try? database.getFile(id: itemId) {
            try? database.deleteFile(id: f.id)
        }
        if let d = try? database.getDirectory(id: itemId) {
            try? database.deleteDirectory(id: d.id)
        }
        try? database.deleteFile(id: itemId)
        try? database.deleteDirectory(id: itemId)
    }

    func insertItemIntoDatabase(_ item: VirtualFileItem) {
        if item.isDirectory {
            try? database.insertDirectory(id: item.id, name: item.name, parentId: item.parentId, encryptedId: item.name, remotePath: item.remotePath ?? "")
        } else {
            try? database.insertFile(id: item.id, name: item.name, parentId: item.parentId, size: item.size, encryptedName: item.name, remotePath: item.remotePath ?? "")
        }
    }
}
