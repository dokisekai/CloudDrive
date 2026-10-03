//
//  CacheDiskStorage.swift
//  CloudDriveCache
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  物理磁盘存储实现
//

import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit

/// 物理磁盘存储管理器
public final class CacheDiskStorage: CacheDiskStorageProtocol, @unchecked Sendable {
    public let cacheDirectory: URL
    private let fileManager = FileManager.default
    
    public var blobsDirectory: URL {
        cacheDirectory.deletingLastPathComponent().appendingPathComponent("Blobs", isDirectory: true)
    }
    
    public init(cacheDirectory: URL = CloudDrivePaths.sharedDirectory.appendingPathComponent("Cache", isDirectory: true)) {
        self.cacheDirectory = cacheDirectory.resolvingSymlinksInPath().standardized
        try? fileManager.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(at: self.blobsDirectory, withIntermediateDirectories: true, attributes: nil)
    }
    
    // MARK: - SHA-256 CAS Helpers
    
    public static func computeSHA256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let bufferSize = 1024 * 1024 // 1MB streaming buffer to prevent memory spikes
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: bufferSize)
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) {}
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    public static func computeSHA256(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    public func localPath(for fileId: String) -> URL {
        CachePathLayout.localPath(fileId: fileId, cacheDirectory: cacheDirectory)
    }
    
    public func exists(fileId: String) -> Bool {
        let path = localPath(for: fileId)
        return fileManager.fileExists(atPath: path.path)
    }
    
    public func fileSize(for fileId: String) -> Int64 {
        let path = localPath(for: fileId)
        let attrs = try? fileManager.attributesOfItem(atPath: path.path)
        return attrs?[.size] as? Int64 ?? 0
    }
    
    public func write(data: Data, for fileId: String) throws {
        let destinationURL = localPath(for: fileId)
        let destDir = destinationURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: destDir.path) {
            try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true, attributes: nil)
        }
        
        // 1. Write to CAS Blobs pool first for deduplication
        let hash = Self.computeSHA256(of: data)
        let prefix = String(hash.prefix(2))
        let blobDir = blobsDirectory.appendingPathComponent(prefix, isDirectory: true)
        let blobURL = blobDir.appendingPathComponent(hash)
        
        if !fileManager.fileExists(atPath: blobURL.path) {
            try? fileManager.createDirectory(at: blobDir, withIntermediateDirectories: true)
            try data.write(to: blobURL, options: .atomic)
        }
        
        // 2. Clone from blob to destination via APFS CoW
        let stagingURL = destDir.appendingPathComponent(".cache_\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: stagingURL) }
        
        if copyfile(blobURL.path, stagingURL.path, nil, copyfile_flags_t(COPYFILE_CLONE)) != 0 {
            try data.write(to: stagingURL, options: .atomic)
        }
        guard rename(stagingURL.path, destinationURL.path) == 0 else {
            try data.write(to: destinationURL, options: .atomic)
            return
        }
    }
    
    public func cache(from sourceURL: URL, for fileId: String) throws -> Int64 {
        let destinationURL = localPath(for: fileId)
        let destDir = destinationURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: destDir.path) {
            try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
        }
        
        if sourceURL.standardizedFileURL == destinationURL.standardizedFileURL {
            return try fileManager.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64 ?? 0
        }
        
        // 1. Content-Addressable Storage (CAS) Deduplication
        let hash = (try? Self.computeSHA256(of: sourceURL)) ?? UUID().uuidString
        let prefix = String(hash.prefix(2))
        let blobDir = blobsDirectory.appendingPathComponent(prefix, isDirectory: true)
        let blobURL = blobDir.appendingPathComponent(hash)
        
        if !fileManager.fileExists(atPath: blobURL.path) {
            try? fileManager.createDirectory(at: blobDir, withIntermediateDirectories: true)
            let blobStaging = blobDir.appendingPathComponent(".staging_\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: blobStaging) }
            if copyfile(sourceURL.path, blobStaging.path, nil, copyfile_flags_t(COPYFILE_CLONE)) != 0 {
                try fileManager.copyItem(at: sourceURL, to: blobStaging)
            }
            _ = rename(blobStaging.path, blobURL.path)
        }
        
        // 2. Clone from deduplicated blob to local cache destination (APFS CoW zero-block clone)
        let stagingURL = destDir.appendingPathComponent(".cache_\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: stagingURL) }
        
        let cloneSource = fileManager.fileExists(atPath: blobURL.path) ? blobURL : sourceURL
        if copyfile(cloneSource.path, stagingURL.path, nil, copyfile_flags_t(COPYFILE_CLONE)) != 0 {
            try fileManager.copyItem(at: cloneSource, to: stagingURL)
        }
        
        // rename replaces atomically without destroying the previous cache on copy failure.
        guard rename(stagingURL.path, destinationURL.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let size = try fileManager.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64 ?? 0
        return size
    }
    
    public func read(fileId: String) throws -> Data {
        let path = localPath(for: fileId)
        return try Data(contentsOf: path)
    }
    
    public func remove(fileId: String) throws {
        let path = localPath(for: fileId)
        if fileManager.fileExists(atPath: path.path) {
            try fileManager.removeItem(at: path)
        }
    }
    
    public func move(from oldFileId: String, to newFileId: String) throws {
        let oldURL = localPath(for: oldFileId)
        let newURL = localPath(for: newFileId)
        
        if fileManager.fileExists(atPath: oldURL.path) {
            let newParentDir = newURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: newParentDir.path) {
                try fileManager.createDirectory(at: newParentDir, withIntermediateDirectories: true)
            }
            if fileManager.fileExists(atPath: newURL.path) {
                try? fileManager.removeItem(at: newURL)
            }
            try fileManager.moveItem(at: oldURL, to: newURL)
        }
    }
    
    public func moveDirectory(from oldDirId: String, to newDirId: String) throws {
        let oldURL = localPath(for: oldDirId)
        let newURL = localPath(for: newDirId)
        
        if fileManager.fileExists(atPath: oldURL.path) {
            let newParentDir = newURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: newParentDir.path) {
                try fileManager.createDirectory(at: newParentDir, withIntermediateDirectories: true)
            }
            if fileManager.fileExists(atPath: newURL.path) {
                try? fileManager.removeItem(at: newURL)
            }
            try fileManager.moveItem(at: oldURL, to: newURL)
        }
    }
    
    public func removeDirectory(forDirectoryPrefix dirPrefix: String) throws {
        let dirPath = localPath(for: dirPrefix)
        if fileManager.fileExists(atPath: dirPath.path) {
            try fileManager.removeItem(at: dirPath)
        }
    }
    
    public func clone(from sourceFileId: String, to destinationFileId: String) throws {
        let sourceURL = localPath(for: sourceFileId)
        let destURL = localPath(for: destinationFileId)
        guard fileManager.fileExists(atPath: sourceURL.path) else { return }
        
        let parentDir = destURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        if fileManager.fileExists(atPath: destURL.path) {
            try? fileManager.removeItem(at: destURL)
        }
        
        if copyfile(sourceURL.path, destURL.path, nil, copyfile_flags_t(COPYFILE_CLONE)) != 0 {
            try fileManager.copyItem(at: sourceURL, to: destURL)
        }
    }
    
    public func clearAll() throws {
        let contents = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
        for url in contents {
            try fileManager.removeItem(at: url)
        }
        if fileManager.fileExists(atPath: blobsDirectory.path) {
            try? fileManager.removeItem(at: blobsDirectory)
            try? fileManager.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)
        }
    }
    
    /// 清理孤立的未被引用的 CAS Blobs
    public func pruneBlobs() {
        guard fileManager.fileExists(atPath: blobsDirectory.path) else { return }
        let allDiskFiles = listAllDiskFiles()
        var activeSizes = Set<Int64>()
        for file in allDiskFiles {
            let p = localPath(for: file)
            if let sz = (try? fileManager.attributesOfItem(atPath: p.path)[.size]) as? Int64 {
                activeSizes.insert(sz)
            }
        }
        
        guard let enumerator = fileManager.enumerator(at: blobsDirectory, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else { return }
        for case let blobURL as URL in enumerator {
            guard let values = try? blobURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]),
                  let isDir = values.isDirectory, !isDir else { continue }
            if let sz = values.fileSize.map({ Int64($0) }), !activeSizes.contains(sz) {
                try? fileManager.removeItem(at: blobURL)
            }
        }
    }
    
    public func listAllDiskFiles() -> Set<String> {
        let resolvedBase = cacheDirectory.resolvingSymlinksInPath().standardized
        guard let enumerator = fileManager.enumerator(
            at: resolvedBase,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        
        var diskFiles: Set<String> = []
        let cacheDirPath = resolvedBase.path
        
        for case let fileURL as URL in enumerator {
            let resolvedURL = fileURL.resolvingSymlinksInPath().standardized
            let lastComp = resolvedURL.lastPathComponent
            if lastComp.hasPrefix("metadata.") || lastComp.hasPrefix(".") || resolvedURL.path.contains("/catalogs/") || resolvedURL.path.contains("/leases/") {
                continue
            }
            guard let resourceValues = try? resolvedURL.resourceValues(forKeys: [.isDirectoryKey]),
                  let isDir = resourceValues.isDirectory, !isDir else {
                continue
            }
            
            guard resolvedURL.path.hasPrefix(cacheDirPath) else { continue }
            let relativePath = String(resolvedURL.path.dropFirst(cacheDirPath.count))
            let fileId = relativePath.hasPrefix("/") ? relativePath : "/" + relativePath
            diskFiles.insert(fileId)
        }
        return diskFiles
    }
    
    public func totalDiskSize() -> Int64 {
        var total: Int64 = 0
        let fm = fileManager
        
        func calculateDirSize(_ dir: URL) -> Int64 {
            var dirTotal: Int64 = 0
            let resolved = dir.resolvingSymlinksInPath().standardized
            guard fm.fileExists(atPath: resolved.path) else { return 0 }
            guard let enumerator = fm.enumerator(
                at: resolved,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return 0 }
            
            for case let fileURL as URL in enumerator {
                let lastComp = fileURL.lastPathComponent
                if lastComp.hasPrefix("metadata.") || lastComp.hasPrefix(".") || fileURL.path.contains("/catalogs/") || fileURL.path.contains("/leases/") {
                    continue
                }
                guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                      let isDir = values.isDirectory, !isDir,
                      let size = values.fileSize else {
                    continue
                }
                dirTotal += Int64(size)
            }
            return dirTotal
        }
        
        total += calculateDirSize(cacheDirectory)
        let resolvedCache = cacheDirectory.resolvingSymlinksInPath().standardized.path
        let resolvedBlobs = blobsDirectory.resolvingSymlinksInPath().standardized.path
        if resolvedCache != resolvedBlobs &&
           !resolvedCache.hasPrefix(resolvedBlobs) &&
           !resolvedBlobs.hasPrefix(resolvedCache) &&
           fm.fileExists(atPath: resolvedBlobs) {
            total += calculateDirSize(blobsDirectory)
        }
        return total
    }
}
