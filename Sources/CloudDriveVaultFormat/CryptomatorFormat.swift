import CloudDriveContracts
import CloudDriveSupport
import CloudDriveCrypto
import Foundation
import CommonCrypto
import CryptomatorCryptoLib

public class CryptomatorFormat {
    private let cryptor: Cryptor
    private let storageClient: StorageClient
    private let basePath: String
    public let scheme: CryptorScheme
    public let shorteningThreshold: Int
    
    public init(
        masterkey: Masterkey,
        storageClient: StorageClient,
        basePath: String,
        scheme: CryptorScheme = .sivGcm,
        shorteningThreshold: Int = 220
    ) {
        self.basePath = basePath.replacingOccurrences(of: "//", with: "/")
        self.scheme = scheme
        self.shorteningThreshold = shorteningThreshold
        self.cryptor = Cryptor(masterkey: masterkey, scheme: scheme)
        self.storageClient = storageClient
    }
    
    public func dirIdData(from stringId: String) -> Data {
        if stringId == "ROOT" || stringId == "" {
            return Data([])
        }
        return stringId.data(using: .utf8) ?? Data([])
    }
    
    public func dirIdString(from data: Data) -> String {
        if data.isEmpty {
            return "ROOT"
        }
        return String(data: data, encoding: .utf8) ?? data.base64EncodedString()
    }
    
    public func getDirPath(dirId: Data) throws -> String {
        let digest = try cryptor.encryptDirId(dirId)
        let i = digest.index(digest.startIndex, offsetBy: 2)
        let cleanBase = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        return "\(cleanBase)/d/\(digest[..<i])/\(digest[i...])"
    }
    
    public func getEncryptedFileName(name: String, parentDirId: Data) throws -> String {
        let normalized = name.precomposedStringWithCanonicalMapping
        let ciphertextBaseName = try cryptor.encryptFileName(normalized, dirId: parentDirId)
        return "\(ciphertextBaseName).c9r"
    }
    
    public func getDecryptedFileName(ciphertextName: String, parentDirId: Data) throws -> String {
        guard ciphertextName.hasSuffix(".c9r") else {
            throw CryptomatorError.invalidCiphertextName
        }
        let baseName = String(ciphertextName.dropLast(4))
        let decrypted = try cryptor.decryptFileName(baseName, dirId: parentDirId)
        return decrypted.precomposedStringWithCanonicalMapping
    }
    
    public func sha1Base64Url(_ string: String) -> String {
        let data = string.data(using: .utf8) ?? Data()
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA1(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }
    
    public func getFileRemotePath(name: String, parentDirId: Data) throws -> (remotePath: String, isShortened: Bool, encName: String, shortenedDirPath: String?) {
        let encName = try getEncryptedFileName(name: name, parentDirId: parentDirId)
        let parentDirPath = try getDirPath(dirId: parentDirId)
        if encName.count > shorteningThreshold {
            let deflatedBase = sha1Base64Url(encName)
            let deflatedDirPath = "\(parentDirPath)/\(deflatedBase).c9s"
            return ("\(deflatedDirPath)/contents.c9r", true, encName, deflatedDirPath)
        } else {
            return ("\(parentDirPath)/\(encName)", false, encName, nil)
        }
    }
    
    public func getDirectoryRemotePath(name: String, parentDirId: Data) throws -> (remotePath: String, isShortened: Bool, encName: String, shortenedDirPath: String?) {
        let encName = try getEncryptedFileName(name: name, parentDirId: parentDirId)
        let parentDirPath = try getDirPath(dirId: parentDirId)
        if encName.count > shorteningThreshold {
            let deflatedBase = sha1Base64Url(encName)
            let deflatedDirPath = "\(parentDirPath)/\(deflatedBase).c9s"
            return (deflatedDirPath, true, encName, deflatedDirPath)
        } else {
            let folderPath = "\(parentDirPath)/\(encName)"
            return (folderPath, false, encName, nil)
        }
    }

    public func listDirectory(dirId: Data) async throws -> [VirtualFileItem] {
        let dirPath = try getDirPath(dirId: dirId)
        
        // A failed or incomplete read must never be reconciled as an empty directory.
        let resources = try await storageClient.listDirectory(path: dirPath)
        
        var items: [VirtualFileItem] = []
        let parentIdStr = dirIdString(from: dirId)
        
        for resource in resources {
            let name = resource.displayName
            
            // Skip metadata and sidecar files (especially AppleDouble ._* and hidden dotfiles created by macOS Finder/WebDAV)
            if name.hasPrefix("._") || name == ".DS_Store" || name == "dir.c9r" || name == "dirid.c9r" || name == "symlink.c9r" || name == "name.c9s" || name == "contents.c9r" {
                continue
            }
            
            if name.hasSuffix(".c9r") {
                // 标准非缩短项目
                let cleartextName: String
                do {
                    cleartextName = try getDecryptedFileName(ciphertextName: name, parentDirId: dirId)
                } catch {
                    Logger.shared.warning(.sync, "Skipping unauthentic or non-base64 ciphertext item: \(name), error: \(error)")
                    continue
                }
                
                let itemPath = "\(dirPath)/\(name)"
                let isDirectory = resource.isDirectory
                let itemFileId: String
                
                if isDirectory {
                    let dirFilePath = "\(itemPath)/dir.c9r"
                    do {
                        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        try await storageClient.downloadFile(path: dirFilePath, to: tempURL) { _ in }
                        let dirIdData = try Data(contentsOf: tempURL)
                        itemFileId = dirIdString(from: dirIdData)
                        try? FileManager.default.removeItem(at: tempURL)
                    } catch {
                        throw error
                    }
                } else {
                    itemFileId = "file_\(name)"
                }
                
                let cleartextSize: Int
                if isDirectory {
                    cleartextSize = 0
                } else {
                    let totalLen = Int(resource.contentLength)
                    if totalLen >= cryptor.fileHeaderSize {
                        cleartextSize = (try? cryptor.calculateCleartextSize(totalLen - cryptor.fileHeaderSize)) ?? 0
                    } else {
                        cleartextSize = 0
                    }
                }
                
                let item = VirtualFileItem(
                    id: itemFileId,
                    name: cleartextName,
                    isDirectory: isDirectory,
                    size: Int64(cleartextSize),
                    modifiedAt: resource.lastModified ?? Date(),
                    parentId: parentIdStr,
                    syncStatus: .synced,
                    localPath: nil,
                    remotePath: itemPath,
                    etag: resource.etag
                )
                items.append(item)
            } else if name.hasSuffix(".c9s") {
                // 缩短长文件名项目 (.c9s 目录)
                let itemDirPath = "\(dirPath)/\(name)"
                
                let subResources = try await storageClient.listDirectory(path: itemDirPath)
                
                guard subResources.contains(where: { $0.displayName == "name.c9s" }) else {
                    throw CryptomatorError.corruptedVault
                }
                
                let nameFilePath = "\(itemDirPath)/name.c9s"
                let tempNameURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: tempNameURL) }
                try await storageClient.downloadFile(path: nameFilePath, to: tempNameURL) { _ in }
                let nameData = try Data(contentsOf: tempNameURL)
                guard let inflatedName = String(data: nameData, encoding: .utf8) else {
                    throw CryptomatorError.corruptedVault
                }
                let cleartextName: String
                do {
                    cleartextName = try getDecryptedFileName(ciphertextName: inflatedName, parentDirId: dirId)
                } catch {
                    Logger.shared.warning(.sync, "Skipping unauthentic or non-base64 inflated ciphertext item: \(inflatedName), error: \(error)")
                    continue
                }

                if subResources.contains(where: { $0.displayName == "dir.c9r" }) {
                    // 是目录
                    let dirFilePath = "\(itemDirPath)/dir.c9r"
                    let tempDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: tempDirURL) }
                    try await storageClient.downloadFile(path: dirFilePath, to: tempDirURL) { _ in }
                    let dirIdData = try Data(contentsOf: tempDirURL)
                    let childDirIdStr = dirIdString(from: dirIdData)
                    
                    let item = VirtualFileItem(
                        id: childDirIdStr,
                        name: cleartextName,
                        isDirectory: true,
                        size: 0,
                        modifiedAt: resource.lastModified ?? Date(),
                        parentId: parentIdStr,
                        syncStatus: .synced,
                        localPath: nil,
                        remotePath: itemDirPath
                    )
                    items.append(item)
                } else if let contentsRes = subResources.first(where: { $0.displayName == "contents.c9r" }) {
                    // 是文件
                    let totalLen = Int(contentsRes.contentLength)
                    let cleartextSize: Int
                    if totalLen >= cryptor.fileHeaderSize {
                        cleartextSize = (try? cryptor.calculateCleartextSize(totalLen - cryptor.fileHeaderSize)) ?? 0
                    } else {
                        cleartextSize = 0
                    }
                    
                    let item = VirtualFileItem(
                        id: "file_\(inflatedName)",
                        name: cleartextName,
                        isDirectory: false,
                        size: Int64(cleartextSize),
                        modifiedAt: contentsRes.lastModified ?? resource.lastModified ?? Date(),
                        parentId: parentIdStr,
                        syncStatus: .synced,
                        localPath: nil,
                        remotePath: "\(itemDirPath)/contents.c9r",
                        etag: contentsRes.etag
                    )
                    items.append(item)
                }
            }
        }
        
        return items
    }
    
    public func createDirectory(name: String, parentDirId: Data, directoryId: String? = nil) async throws -> VirtualFileItem {
        let newDirIdData = (directoryId ?? UUID().uuidString).data(using: .utf8)!
        let newDirIdStr = dirIdString(from: newDirIdData)
        let parentIdStr = dirIdString(from: parentDirId)
        
        let (folderC9rPath, isShortened, encName, shortenedDirPath) = try getDirectoryRemotePath(name: name, parentDirId: parentDirId)
        let parentDirPath = try getDirPath(dirId: parentDirId)
        
        if (try? await storageClient.exists(path: parentDirPath)) != true {
            try await storageClient.createDirectory(path: parentDirPath)
        }
        
        // A replay of an offline mkdir retains its original directory identity.
        // Never replace an existing pointer with a newly generated UUID.
        let pointerPath = "\(folderC9rPath)/dir.c9r"
        if try await storageClient.exists(path: pointerPath) {
            let pointerURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: pointerURL) }
            try await storageClient.downloadFile(path: pointerPath, to: pointerURL) { _ in }
            let existingId = try Data(contentsOf: pointerURL)
            guard directoryId != nil, existingId == newDirIdData else {
                throw StorageError.serverError(statusCode: 409, message: "A directory with this name already exists")
            }
            // A previous attempt may have committed the pointer but not the content directory.
            try await storageClient.createDirectory(path: getDirPath(dirId: existingId))
            return VirtualFileItem(id: newDirIdStr, name: name, isDirectory: true, size: 0, modifiedAt: Date(), parentId: parentIdStr, remotePath: folderC9rPath)
        }
        // 1. Create content directory on remote storage FIRST, before publishing pointer!
        let actualDirPath = try getDirPath(dirId: newDirIdData)
        try await storageClient.createDirectory(path: actualDirPath)
        
        // 写入备份父目录ID (dirid.c9r) - 兼容 Cryptomator 官方规范
        let tempIdURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ciphertextDirIdURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: tempIdURL)
            try? FileManager.default.removeItem(at: ciphertextDirIdURL)
        }
        if (try? parentDirId.write(to: tempIdURL)) != nil {
            if (try? cryptor.encryptContent(from: tempIdURL, to: ciphertextDirIdURL)) != nil {
                _ = try? await storageClient.uploadFile(localURL: ciphertextDirIdURL, to: "\(actualDirPath)/dirid.c9r", mode: .createIfAbsent) { _ in }
            }
        }

        // 2. Ensure folder c9r entry exists
        try await storageClient.createDirectory(path: folderC9rPath)
        
        // 3. If shortened name, write name.c9s
        if isShortened, let sDir = shortenedDirPath {
            if (try? await storageClient.exists(path: sDir)) != true {
                try await storageClient.createDirectory(path: sDir)
            }
            let tempNameURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: tempNameURL) }
            if let encData = encName.data(using: .utf8) {
                try encData.write(to: tempNameURL)
                _ = try? await storageClient.uploadFile(localURL: tempNameURL, to: "\(sDir)/name.c9s", mode: .createIfAbsent) { _ in }
            }
        }
        
        // 4. Atomically commit pointer dir.c9r with createIfAbsent
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try newDirIdData.write(to: tempURL)
        do {
            try await storageClient.uploadFile(localURL: tempURL, to: pointerPath, mode: .createIfAbsent) { _ in }
        } catch {
            if (error as? StorageError)?.isPreconditionFailure == true {
                let pointerCheckURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: pointerCheckURL) }
                if (try? await storageClient.downloadFile(path: pointerPath, to: pointerCheckURL) { _ in }) != nil,
                   let existingId = try? Data(contentsOf: pointerCheckURL),
                   directoryId != nil, existingId == newDirIdData {
                    return VirtualFileItem(id: newDirIdStr, name: name, isDirectory: true, size: 0, modifiedAt: Date(), parentId: parentIdStr, remotePath: folderC9rPath)
                }
                throw StorageError.serverError(statusCode: 409, message: "A directory with this name already exists")
            }
            throw error
        }
        
        return VirtualFileItem(
            id: newDirIdStr,
            name: name,
            isDirectory: true,
            size: 0,
            modifiedAt: Date(),
            parentId: parentIdStr,
            syncStatus: .synced,
            localPath: nil,
            remotePath: folderC9rPath
        )
    }

    public func uploadFile(localURL: URL, name: String, parentDirId: Data, expectedETag: String? = nil) async throws -> VirtualFileItem {
        let mode: StorageWriteMode = expectedETag != nil ? .replace(expectedETag: expectedETag!) : .createIfAbsent
        return try await uploadFile(localURL: localURL, name: name, parentDirId: parentDirId, mode: mode)
    }

    public func uploadFile(localURL: URL, name: String, parentDirId: Data, mode: StorageWriteMode) async throws -> VirtualFileItem {
        let (fileC9rPath, isShortened, encName, shortenedDirPath) = try getFileRemotePath(name: name, parentDirId: parentDirId)
        let parentDirPath = try getDirPath(dirId: parentDirId)
        
        let ciphertextURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: ciphertextURL) }
        
        try cryptor.encryptContent(from: localURL, to: ciphertextURL)
        
        if isShortened, let sDir = shortenedDirPath {
            if (try? await storageClient.exists(path: sDir)) != true {
                try await storageClient.createDirectory(path: sDir)
            }
            let tempNameURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: tempNameURL) }
            if let encData = encName.data(using: .utf8) {
                try encData.write(to: tempNameURL)
                _ = try? await storageClient.uploadFile(localURL: tempNameURL, to: "\(sDir)/name.c9s", mode: .createIfAbsent) { _ in }
            }
        } else {
            if (try? await storageClient.exists(path: parentDirPath)) != true {
                try await storageClient.createDirectory(path: parentDirPath)
            }
        }
        
        let committedETag = try await storageClient.uploadFile(localURL: ciphertextURL, to: fileC9rPath, mode: mode) { _ in }
        
        let attrs = (try? FileManager.default.attributesOfItem(atPath: localURL.path)) ?? [:]
        let fileSize = attrs[.size] as? Int64 ?? 0
        let modDate = attrs[.modificationDate] as? Date ?? Date()
        
        let parentIdStr = dirIdString(from: parentDirId)
        
        return VirtualFileItem(
            id: "file_\(encName)",
            name: name,
            isDirectory: false,
            size: fileSize,
            modifiedAt: modDate,
            parentId: parentIdStr,
            syncStatus: .synced,
            localPath: nil,
            remotePath: fileC9rPath,
            etag: committedETag
        )
    }
    
    @discardableResult
    public func downloadFile(remotePath: String, to localURL: URL, expectedETag: String? = nil, progress: ((Double) -> Void)? = nil) async throws -> String? {
        let ciphertextURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: ciphertextURL) }
        
        let downloadedETag = try await storageClient.downloadFile(path: remotePath, to: ciphertextURL, expectedETag: expectedETag) { p in
            progress?(p * 0.9)
        }
        
        let parentDir = localURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        
        let cipherAttrs = (try? FileManager.default.attributesOfItem(atPath: ciphertextURL.path)) ?? [:]
        let cipherSize = cipherAttrs[.size] as? Int ?? 0
        guard cipherSize >= 68 else {
            throw CryptomatorError.corruptedVault
        }
        
        let cleartextStagedURL = parentDir.appendingPathComponent(".clouddrive-decrypt-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cleartextStagedURL) }
        try cryptor.decryptContent(from: ciphertextURL, to: cleartextStagedURL)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: localURL.path) {
            _ = try FileManager.default.replaceItemAt(localURL, withItemAt: cleartextStagedURL)
        } else {
            try FileManager.default.moveItem(at: cleartextStagedURL, to: localURL)
        }
        progress?(1.0)
        return downloadedETag
    }
    
    public func deleteItem(remotePath: String, dirIdData: Data?) async throws {
        var visited = Set<Data>()
        try await deleteItem(remotePath: remotePath, dirIdData: dirIdData, visited: &visited)
    }

    private func deleteItem(remotePath: String, dirIdData: Data?, visited: inout Set<Data>) async throws {
        if let directoryId = dirIdData {
            guard visited.insert(directoryId).inserted else { throw CryptomatorError.corruptedVault }
            // Ciphertext content directories are flattened, so backend recursion alone
            // cannot remove descendants. Read every child before removing the pointer.
            let children = try await listDirectory(dirId: directoryId)
            for child in children {
                guard let path = child.remotePath else { throw CryptomatorError.corruptedVault }
                try await deleteItem(remotePath: path, dirIdData: child.isDirectory ? self.dirIdData(from: child.id) : nil, visited: &visited)
            }
            try await storageClient.delete(path: getDirPath(dirId: directoryId))
        }
        let targetPath = remotePath.hasSuffix("/contents.c9r") && remotePath.contains(".c9s/")
            ? (remotePath as NSString).deletingLastPathComponent : remotePath
        try await storageClient.delete(path: targetPath)
    }
}
