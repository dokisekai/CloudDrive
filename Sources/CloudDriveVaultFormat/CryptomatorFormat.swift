import CloudDriveContracts
import CloudDriveSupport
import CloudDriveCrypto
import Foundation
import CommonCrypto
import CryptomatorCryptoLib

public final class CryptomatorFormat {
    private let cryptor: Cryptor
    private let masterkey: Masterkey
    private let storageClient: StorageClient
    private let basePath: String
    public let scheme: CryptorScheme
    public let shorteningThreshold: Int
    private var headerCache = [String: CryptomatorDecryptedHeader]()
    private let headerCacheLock = NSLock()
    private var dirIdCache = [String: String]()
    private let dirIdCacheLock = NSLock()
    
    public func getCachedDirId(for remotePath: String) -> String? {
        dirIdCacheLock.lock()
        defer { dirIdCacheLock.unlock() }
        return dirIdCache[remotePath]
    }
    
    public func setCachedDirId(_ id: String, for remotePath: String) {
        dirIdCacheLock.lock()
        defer { dirIdCacheLock.unlock() }
        if dirIdCache.count > 1000 {
            dirIdCache.removeAll()
        }
        dirIdCache[remotePath] = id
    }
    
    public func removeCachedDirId(for remotePath: String) {
        dirIdCacheLock.lock()
        defer { dirIdCacheLock.unlock() }
        dirIdCache.removeValue(forKey: remotePath)
    }
    
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
        self.masterkey = masterkey
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
            .replacingOccurrences(of: "=", with: "")
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
            let name = resource.displayName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            
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
                    if let cachedId = getCachedDirId(for: itemPath) {
                        itemFileId = cachedId
                    } else {
                        let dirFilePath = "\(itemPath)/dir.c9r"
                        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        defer { try? FileManager.default.removeItem(at: tempURL) }
                        do {
                            try await storageClient.downloadFile(path: dirFilePath, to: tempURL) { _ in }
                            let dirIdData = try Data(contentsOf: tempURL)
                            itemFileId = dirIdString(from: dirIdData)
                            setCachedDirId(itemFileId, for: itemPath)
                        } catch {
                            Logger.shared.warning(.sync, "Skipping unreadable or missing directory pointer in \(itemPath): \(error)")
                            continue
                        }
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
                
                guard subResources.contains(where: { $0.displayName.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "name.c9s" }) else {
                    throw CryptomatorError.corruptedVault
                }
                
                let nameFilePath = "\(itemDirPath)/name.c9s"
                let tempNameURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: tempNameURL) }
                try await storageClient.downloadFile(path: nameFilePath, to: tempNameURL) { _ in }
                let nameData = try Data(contentsOf: tempNameURL)
                guard let inflatedNameRaw = String(data: nameData, encoding: .utf8) else {
                    throw CryptomatorError.corruptedVault
                }
                let inflatedName = inflatedNameRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleartextName: String
                do {
                    cleartextName = try getDecryptedFileName(ciphertextName: inflatedName, parentDirId: dirId)
                } catch {
                    Logger.shared.warning(.sync, "Skipping unauthentic or non-base64 inflated ciphertext item: \(inflatedName), error: \(error)")
                    continue
                }

                if subResources.contains(where: { $0.displayName.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "dir.c9r" }) {
                    // 是目录
                    let childDirIdStr: String
                    if let cachedId = getCachedDirId(for: itemDirPath) {
                        childDirIdStr = cachedId
                    } else {
                        let dirFilePath = "\(itemDirPath)/dir.c9r"
                        let tempDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        defer { try? FileManager.default.removeItem(at: tempDirURL) }
                        do {
                            try await storageClient.downloadFile(path: dirFilePath, to: tempDirURL) { _ in }
                            let dirIdData = try Data(contentsOf: tempDirURL)
                            childDirIdStr = dirIdString(from: dirIdData)
                            setCachedDirId(childDirIdStr, for: itemDirPath)
                        } catch {
                            Logger.shared.warning(.sync, "Skipping unreadable or missing directory pointer in shortened dir \(itemDirPath): \(error)")
                            continue
                        }
                    }
                    
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
                } else if let contentsRes = subResources.first(where: { $0.displayName.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "contents.c9r" }) {
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
                    setCachedDirId(newDirIdStr, for: folderC9rPath)
                    return VirtualFileItem(id: newDirIdStr, name: name, isDirectory: true, size: 0, modifiedAt: Date(), parentId: parentIdStr, remotePath: folderC9rPath)
                }
                throw StorageError.serverError(statusCode: 409, message: "A directory with this name already exists")
            }
            throw error
        }
        
        setCachedDirId(newDirIdStr, for: folderC9rPath)
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

    /// 维护 Cryptomator 官方规范：当目录被移动到新父目录时，更新其内容目录下的加密父指针 dirid.c9r
    public func updateDirectoryParentId(dirIdData: Data, newParentDirId: Data) async {
        guard let actualDirPath = try? getDirPath(dirId: dirIdData) else { return }
        let tempIdURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ciphertextDirIdURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: tempIdURL)
            try? FileManager.default.removeItem(at: ciphertextDirIdURL)
        }
        if (try? newParentDirId.write(to: tempIdURL)) != nil {
            if (try? cryptor.encryptContent(from: tempIdURL, to: ciphertextDirIdURL)) != nil {
                _ = try? await storageClient.uploadFile(localURL: ciphertextDirIdURL, to: "\(actualDirPath)/dirid.c9r", mode: .forceOverwrite) { _ in }
            }
        }
    }

    public func uploadFile(localURL: URL, name: String, parentDirId: Data, expectedETag: String? = nil) async throws -> VirtualFileItem {
        let mode: StorageWriteMode = expectedETag != nil ? .replace(expectedETag: expectedETag!) : .createIfAbsent
        return try await uploadFile(localURL: localURL, name: name, parentDirId: parentDirId, mode: mode)
    }

    public func uploadFile(localURL: URL, name: String, parentDirId: Data, mode: StorageWriteMode, progress: ((Double) -> Void)? = nil) async throws -> VirtualFileItem {
        let (fileC9rPath, isShortened, encName, shortenedDirPath) = try getFileRemotePath(name: name, parentDirId: parentDirId)
        let parentDirPath = try getDirPath(dirId: parentDirId)
        let attrs = (try? FileManager.default.attributesOfItem(atPath: localURL.path)) ?? [:]
        let fileSize = attrs[.size] as? Int64 ?? 0
        let modDate = attrs[.modificationDate] as? Date ?? Date()

        let tempDir = FileManager.default.temporaryDirectory
        let freeSpace = DiskSpaceHelper.currentDiskSpace(at: tempDir).availableBytes
        let requiredSpace = fileSize + 50 * 1024 * 1024
        if fileSize > 50 * 1024 * 1024 && freeSpace < requiredSpace {
            throw StorageError.serverError(statusCode: 507, message: "本地磁盘空间不足，无法暂存加密文件 (需 \(requiredSpace / 1024 / 1024)MB，剩余 \(freeSpace / 1024 / 1024)MB)")
        }

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
                _ = try await storageClient.uploadFile(localURL: tempNameURL, to: "\(sDir)/name.c9s", mode: .createIfAbsent) { _ in }
            }
        } else {
            if (try? await storageClient.exists(path: parentDirPath)) != true {
                try await storageClient.createDirectory(path: parentDirPath)
            }
        }
        
        let committedETag: String?
        do {
            committedETag = try await storageClient.uploadFile(localURL: ciphertextURL, to: fileC9rPath, mode: mode) { p in progress?(p) }
        } catch {
            // Re-encryption uses fresh random nonces, so compare decrypted bytes,
            // not freshly generated ciphertext or only file metadata.
            if StorageContentVerification.mayHaveCommitted(error),
               let verified = try? await verifiedCleartextRevision(localURL: localURL, remotePath: fileC9rPath) {
                try Task.checkCancellation()
                committedETag = verified
                progress?(1)
            } else { try Task.checkCancellation(); throw error }
        }
        
        headerCacheLock.withLock { headerCache.removeAll() }
        
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
    

    private func verifiedCleartextRevision(localURL: URL, remotePath: String) async throws -> String? {
        guard let resource = try await storageClient.currentResource(path: remotePath), !resource.isDirectory,
              let etag = resource.etag, !etag.hasPrefix("W/"), etag.hasPrefix("\""), etag.hasSuffix("\"") else { return nil }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("cleartext-verify-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let size = try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        guard size >= 0, Int64(size) < Int64.max / 2 else { return nil }
        let expectedCipherSize = CryptomatorRandomAccess.calculateCiphertextSize(cleartextSize: Int64(size))
        guard resource.contentLength == expectedCipherSize else { return nil }
        let delivered = try await downloadFile(remotePath: remotePath, to: temporary, expectedETag: etag, maximumCiphertextBytes: expectedCipherSize)
        guard delivered == etag, try StorageContentVerification.identical(localURL, temporary) else { return nil }
        try Task.checkCancellation()
        return etag
    }

    @discardableResult
    public func downloadFile(remotePath: String, to localURL: URL, expectedETag: String? = nil, maximumCiphertextBytes: Int64? = nil, progress: ((Double) -> Void)? = nil) async throws -> String? {
        let ciphertextURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: ciphertextURL) }
        
        let downloadedETag: String?
        if let maximumCiphertextBytes {
            downloadedETag = try await storageClient.downloadFile(path: remotePath, to: ciphertextURL, expectedETag: expectedETag, maximumBytes: maximumCiphertextBytes) { progress?($0 * 0.9) }
        } else {
            downloadedETag = try await storageClient.downloadFile(path: remotePath, to: ciphertextURL, expectedETag: expectedETag) { progress?($0 * 0.9) }
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

    /// 32KB 分块随机解密与局部 Range 读取
    public func readCleartextRange(
        remotePath: String,
        cleartextRange: ClosedRange<Int64>,
        totalCiphertextSize: Int64? = nil,
        expectedETag: String? = nil
    ) async throws -> Data {
        guard cleartextRange.lowerBound >= 0, cleartextRange.upperBound < Int64.max / 2,
              cleartextRange.upperBound - cleartextRange.lowerBound < 16 * 1024 * 1024 else {
            throw StorageError.notSupported("Invalid or oversized cleartext range")
        }
        let revision: String?
        let snapshotSize: Int64?
        let cacheKey: String
        if storageClient.requiresETagForUpdate {
            guard let resource = try await storageClient.currentResource(path: remotePath), !resource.isDirectory,
                  let etag = resource.etag, etag.hasPrefix("\""), etag.hasSuffix("\""), !etag.hasPrefix("W/") else {
                throw StorageError.notSupported("Encrypted range reads require a strong remote revision")
            }
            if let expectedETag, expectedETag != etag { throw StorageError.serverError(statusCode: 412, message: "Requested content revision is no longer current") }
            revision = etag
            snapshotSize = resource.contentLength
            cacheKey = "\(remotePath.utf8.count):\(remotePath)\(etag)"
        } else {
            // A provider without conditional reads cannot safely assemble two GETs.
            let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent("cipher-range-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: snapshot) }
            let delivered = try await storageClient.downloadFile(path: remotePath, to: snapshot, expectedETag: expectedETag) { _ in }
            if let expectedETag, delivered != expectedETag { throw StorageError.serverError(statusCode: 412, message: "Requested content revision could not be verified") }
            let handle = try FileHandle(forReadingFrom: snapshot)
            defer { try? handle.close() }
            let headerData = try handle.read(upToCount: Int(CryptomatorRandomAccess.headerSize)) ?? Data()
            let header = try CryptomatorRandomAccess.decryptHeader(headerData: headerData, masterkey: masterkey)
            let size = try snapshot.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return try readSnapshotRange(handle: handle, header: header, range: cleartextRange, ciphertextSize: Int64(size))
        }
        let (startChunk, endChunk) = CryptomatorRandomAccess.chunkRange(forCleartextRange: cleartextRange)
        
        // 1. 获取并解密 68 字节的文件头（优先内存缓存）
        let header: CryptomatorDecryptedHeader
        let cached = headerCacheLock.withLock { headerCache[cacheKey] }
        
        if let cached = cached {
            header = cached
        } else {
            let headerData = try await storageClient.downloadRange(
                path: remotePath,
                range: 0...(CryptomatorRandomAccess.headerSize - 1), expectedETag: revision
            )
            header = try CryptomatorRandomAccess.decryptHeader(headerData: headerData, masterkey: masterkey)
            headerCacheLock.withLock {
                if headerCache.count > 500 { headerCache.removeAll() }
                headerCache[cacheKey] = header
            }
        }
        
        // 2. 一次性通过 HTTP Range 请求下载覆盖从 startChunk 到 endChunk 的所有密文分块
        let cipherRange = CryptomatorRandomAccess.contiguousCiphertextRange(
            startChunk: startChunk,
            endChunk: endChunk,
            totalCiphertextSize: snapshotSize
        )
        let ciphertextData = try await storageClient.downloadRange(path: remotePath, range: cipherRange, expectedETag: revision)
        
        // 3. 逐块解密并提取所需的明文字节切片
        var result = Data()
        let fullChunkCipherSize = Int(CryptomatorRandomAccess.fullCiphertextChunkSize)
        
        for chunkIdx in startChunk...endChunk {
            let offsetInCiphertextData = Int(chunkIdx - startChunk) * fullChunkCipherSize
            guard offsetInCiphertextData < ciphertextData.count else { break }
            let chunkLen = min(fullChunkCipherSize, ciphertextData.count - offsetInCiphertextData)
            let chunkCiphertext = ciphertextData.subdata(in: offsetInCiphertextData..<(offsetInCiphertextData + chunkLen))
            
            let cleartextChunk = try CryptomatorRandomAccess.decryptChunk(
                chunkCiphertext: chunkCiphertext,
                chunkIndex: UInt64(chunkIdx),
                header: header
            )
            
            let chunkPlaintextStart = chunkIdx * CryptomatorRandomAccess.cleartextChunkSize
            let sliceStart = max(0, Int(cleartextRange.lowerBound - chunkPlaintextStart))
            let sliceEnd = min(cleartextChunk.count, Int(cleartextRange.upperBound - chunkPlaintextStart + 1))
            
            if sliceStart < sliceEnd && sliceStart < cleartextChunk.count {
                result.append(cleartextChunk.subdata(in: sliceStart..<sliceEnd))
            }
        }
        
        return result
    }
    

    private func readSnapshotRange(handle: FileHandle, header: CryptomatorDecryptedHeader, range: ClosedRange<Int64>, ciphertextSize: Int64) throws -> Data {
        let (start, end) = CryptomatorRandomAccess.chunkRange(forCleartextRange: range)
        var result = Data()
        for index in start...end {
            try Task.checkCancellation()
            let offset = CryptomatorRandomAccess.headerSize + index * CryptomatorRandomAccess.fullCiphertextChunkSize
            if offset >= ciphertextSize { break }
            try handle.seek(toOffset: UInt64(offset))
            let count = Int(min(CryptomatorRandomAccess.fullCiphertextChunkSize, ciphertextSize - offset))
            let cipher = try handle.read(upToCount: count) ?? Data()
            guard cipher.count == count else { throw StorageError.serverError(statusCode: 502, message: "Incomplete ciphertext snapshot") }
            let plain = try CryptomatorRandomAccess.decryptChunk(chunkCiphertext: cipher, chunkIndex: UInt64(index), header: header)
            let lower = Int(max(0, range.lowerBound - index * CryptomatorRandomAccess.cleartextChunkSize))
            let upper = Int(min(Int64(plain.count), range.upperBound - index * CryptomatorRandomAccess.cleartextChunkSize + 1))
            if lower < upper { result.append(plain.subdata(in: lower..<upper)) }
        }
        return result
    }

    /// Delete only the parent entry. Cryptomator's descendant data directories
    /// live elsewhere under d/ and remain unreachable for a later collector.
    /// No remote listing, child walk or sequence of DELETE requests occurs here.
    public func deleteItem(remotePath: String, dirIdData: Data?, expectedETag: String? = nil) async throws {
        let isShortened = remotePath.hasSuffix("/contents.c9r") && remotePath.contains(".c9s/")
        let shortenedParent = isShortened ? (remotePath as NSString).deletingLastPathComponent : nil
        let targetPath = shortenedParent ?? remotePath
        let revision = dirIdData == nil ? expectedETag : StorageContentVerification.collectionDeletionETag(expectedETag)
        do { try await storageClient.delete(path: targetPath, expectedETag: revision) }
        catch {
            if revision == nil, dirIdData != nil, StorageContentVerification.deletionOutcomeIsUncertain(error) {
                throw StorageError.indeterminateMutation("Encrypted parent-entry DELETE must be checked before another deletion")
            }
            throw error
        }
        headerCacheLock.withLock {
            headerCache.removeValue(forKey: remotePath)
            if let sp = shortenedParent { headerCache.removeValue(forKey: sp) }
        }
        removeCachedDirId(for: remotePath)
    }
}
