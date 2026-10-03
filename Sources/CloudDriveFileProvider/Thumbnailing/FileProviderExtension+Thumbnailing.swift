//
//  FileProviderExtension+Thumbnailing.swift
//  CloudDriveFileProvider
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  File Provider 缩略图生成与流式提供扩展
//

import Foundation
import FileProvider
import CloudDriveCore

extension FileProviderExtension {
    
    // MARK: - NSFileProviderThumbnailing
    
    func fetchThumbnails(
        for itemIdentifiers: [NSFileProviderItemIdentifier],
        requestedSize size: CGSize,
        perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        let thumbnailManager = ThumbnailManager.shared
        
        let task = Task { [weak self] in
            guard let self = self else {
                completionHandler(progress.isCancelled ? CocoaError(.userCancelled) : nil)
                return
            }
            
            do { try await self.ensureVaultUnlocked() }
            catch { completionHandler(error); return }
            for identifier in itemIdentifiers {
                guard !progress.isCancelled else { break }
                let fileId = identifier.rawValue
                let thumbnailId = self.thumbnailIdentifier(fileId)
                
                do {
                    // 1. Check VFS item metadata and supported types
                    guard let vfsItem = try? self.vfs.getItem(id: fileId), !vfsItem.isDirectory else {
                        perThumbnailCompletionHandler(identifier, nil, nil)
                        progress.completedUnitCount += 1
                        continue
                    }
                    
                    let ext = (vfsItem.name as NSString).pathExtension.lowercased()
                    guard ThumbnailManager.isSupported(extension: ext) else {
                        perThumbnailCompletionHandler(identifier, nil, nil)
                        progress.completedUnitCount += 1
                        continue
                    }
                    
                    let fileModifiedTimestamp = Int64(vfsItem.modifiedAt.timeIntervalSince1970)
                    
                    // 2. Prioritize local thumbnail persistent cache (with timestamp, auto invalidates if source modified)
                    if let cachedData = thumbnailManager.getCachedThumbnailData(fileId: thumbnailId, size: size, timestamp: fileModifiedTimestamp) {
                        perThumbnailCompletionHandler(identifier, cachedData, nil)
                        progress.completedUnitCount += 1
                        continue
                    }
                    
                    // 3. Extract a thumbnail locally without modifying the user's remote directory.
                    if self.cacheManager.isCached(fileId: fileId) {
                        let localURL = self.cacheManager.localPath(for: fileId)
                        if let data = thumbnailManager.generateThumbnail(from: localURL, fileId: thumbnailId, size: size, timestamp: fileModifiedTimestamp) {
                            perThumbnailCompletionHandler(identifier, data, nil)
                            progress.completedUnitCount += 1
                            continue
                        }
                    }
                    
                    // 5. Not cached locally: for small files (<= 30MB), download temporarily to generate thumbnail, then remove temp file
                    //    Files > 30MB skipped to avoid draining network and disk resources
                    if vfsItem.size <= ThumbnailManager.maxAutoDownloadSizeForThumbnail {
                        let tempURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent("thumb_\(UUID().uuidString).\(ext)")
                        
                        defer { try? FileManager.default.removeItem(at: tempURL) }
                        try await self.vfs.downloadFile(fileId: fileId, to: tempURL)
                        try Task.checkCancellation()
                        let data = thumbnailManager.generateThumbnail(from: tempURL, fileId: thumbnailId, size: size, timestamp: fileModifiedTimestamp)
                        try? FileManager.default.removeItem(at: tempURL)
                        
                        perThumbnailCompletionHandler(identifier, data, nil)
                    } else {
                        // Large dataless file: return nil safely to display system default icon
                        perThumbnailCompletionHandler(identifier, nil, nil)
                    }
                } catch {
                    perThumbnailCompletionHandler(identifier, nil, nil)
                }
                
                progress.completedUnitCount += 1
            }
            
            completionHandler(progress.isCancelled ? CocoaError(.userCancelled) : nil)
        }
        
        progress.cancellationHandler = { task.cancel() }
        return progress
    }
}
