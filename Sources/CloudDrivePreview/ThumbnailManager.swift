//
//  ThumbnailManager.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  跨格式缩略图生成与持久化缓存管理器（支持图片、PDF、视频等）
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

public final class ThumbnailManager {
    public static let shared = ThumbnailManager()
    
    /// 缩略图缓存最大容量（默认 500 MB）
    public static let maxThumbnailCacheSize: Int64 = 500 * 1024 * 1024
    
    /// 未下载文件自动生成缩略图的最大文件大小（默认 30 MB，防止大视频被全量拉取）
    public static let maxAutoDownloadSizeForThumbnail: Int64 = 30 * 1024 * 1024
    
    private let cacheDir = CloudDrivePaths.thumbnailsDirectory
    private let queue = DispatchQueue(label: "com.clouddrive.thumbnails.queue", attributes: .concurrent)
    
    private var estimatedCacheSize: Int64 = -1
    private var saveCountSinceLastCheck: Int = 0

    // MARK: - 支持的文件格式定义
    
    public static let supportedImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "tiff", "tif", "ico"
    ]
    
    public static let supportedDocumentExtensions: Set<String> = [
        "pdf"
    ]
    
    public static let supportedVideoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "webm", "flv", "wmv", "ts"
    ]
    
    private init() {
        // 确保缩略图缓存目录存在
        if !FileManager.default.fileExists(atPath: cacheDir.path) {
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
    }
    
    // MARK: - 类型判断
    
    public static func isSupported(extension ext: String) -> Bool {
        let lower = ext.lowercased()
        return isImage(extension: lower) || isDocument(extension: lower) || isVideo(extension: lower)
    }
    
    public static func isImage(extension ext: String) -> Bool {
        supportedImageExtensions.contains(ext.lowercased())
    }
    
    public static func isDocument(extension ext: String) -> Bool {
        supportedDocumentExtensions.contains(ext.lowercased())
    }
    
    public static func isVideo(extension ext: String) -> Bool {
        supportedVideoExtensions.contains(ext.lowercased())
    }
    
    // MARK: - 缓存键与路径
    
    public func cacheKey(fileId: String, size: CGSize, timestamp: Int64? = nil) -> String {
        let safeId = fileId.replacingOccurrences(of: "/", with: "_")
                           .replacingOccurrences(of: ":", with: "_")
        if let ts = timestamp, ts > 0 {
            return "\(safeId)_\(ts)_\(Int(size.width))x\(Int(size.height)).jpg"
        }
        return "\(safeId)_\(Int(size.width))x\(Int(size.height)).jpg"
    }
    
    public func cachedThumbnailURL(fileId: String, size: CGSize, timestamp: Int64? = nil) -> URL? {
        let key = cacheKey(fileId: fileId, size: size, timestamp: timestamp)
        let url = cacheDir.appendingPathComponent(key)
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        // 如果指定了具体时间戳但带时间戳的不存在，表明尚未生成或旧缓存已失效，不返回旧图
        if timestamp != nil {
            return nil
        }
        let fallbackKey = cacheKey(fileId: fileId, size: size, timestamp: nil)
        let fallbackURL = cacheDir.appendingPathComponent(fallbackKey)
        return FileManager.default.fileExists(atPath: fallbackURL.path) ? fallbackURL : nil
    }
    
    public func getCachedThumbnailData(fileId: String, size: CGSize, timestamp: Int64? = nil) -> Data? {
        guard let url = cachedThumbnailURL(fileId: fileId, size: size, timestamp: timestamp) else { return nil }
        return try? Data(contentsOf: url)
    }
    
    // MARK: - 缩略图生成核心入口
    
    /// 从指定本地文件直接生成缩略图数据（支持图片、PDF、视频，带时间戳版本管理）
    public func generateThumbnail(from localURL: URL, fileId: String, size: CGSize, timestamp: Int64? = nil) -> Data? {
        let ext = localURL.pathExtension.lowercased()
        
        var generatedData: Data? = nil
        if Self.isVideo(extension: ext) {
            generatedData = generateVideoThumbnail(from: localURL, size: size)
        } else if Self.isDocument(extension: ext) {
            generatedData = generatePDFThumbnail(from: localURL, size: size)
        } else if Self.isImage(extension: ext) {
            generatedData = generateImageThumbnail(from: localURL, size: size)
        }
        
        if let data = generatedData {
            saveThumbnailToCache(data: data, fileId: fileId, size: size, timestamp: timestamp)
        }
        return generatedData
    }
    
    // MARK: - 图片缩略图生成 (基于 ImageIO 极速下采样)
    
    public func generateImageThumbnail(from fileURL: URL, size: CGSize) -> Data? {
        let maxPixelSize = max(size.width, size.height, 128)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary)
        else {
            return nil
        }
        
        return compressCGImageToJPEG(cgImage: cgImage)
    }
    
    // MARK: - PDF 缩略图生成 (基于 CoreGraphics 栅格化第 1 页)
    
    public func generatePDFThumbnail(from fileURL: URL, size: CGSize) -> Data? {
        guard let pdfDoc = CGPDFDocument(fileURL as CFURL),
              let page = pdfDoc.page(at: 1)
        else {
            return nil
        }
        
        let pageRect = page.getBoxRect(.mediaBox)
        guard pageRect.width > 0 && pageRect.height > 0 else { return nil }
        
        let scale = min(size.width / pageRect.width, size.height / pageRect.height)
        let targetWidth = max(Int(pageRect.width * scale), 32)
        let targetHeight = max(Int(pageRect.height * scale), 32)
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.drawPDFPage(page)
        context.restoreGState()
        
        guard let cgImage = context.makeImage() else { return nil }
        return compressCGImageToJPEG(cgImage: cgImage)
    }
    
    // MARK: - 视频缩略图生成 (基于 AVAssetImageGenerator 提取关键帧)
    
    public func generateVideoThumbnail(from fileURL: URL, size: CGSize) -> Data? {
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: size.width * 2, height: size.height * 2)
        
        // 优先在第 1.0 秒提取（避免很多视频开头是全黑帧）；如果视频总长不足 1 秒则提取首帧
        let durationSeconds = CMTimeGetSeconds(asset.duration)
        let targetSeconds: Double
        if durationSeconds.isFinite && durationSeconds > 1.5 {
            targetSeconds = 1.0
        } else if durationSeconds.isFinite && durationSeconds > 0.1 {
            targetSeconds = durationSeconds / 2.0
        } else {
            targetSeconds = 0.0
        }
        
        let time = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        
        do {
            let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
            return compressCGImageToJPEG(cgImage: cgImage)
        } catch {
            // 如果指定时间提取失败，尝试首帧
            if targetSeconds != 0.0 {
                if let fallbackImage = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                    return compressCGImageToJPEG(cgImage: fallbackImage)
                }
            }
            return nil
        }
    }
    
    // MARK: - 缓存存储与清理
    
    public func saveThumbnailToCache(data: Data, fileId: String, size: CGSize, timestamp: Int64? = nil) {
        queue.async(flags: .barrier) {
            let key = self.cacheKey(fileId: fileId, size: size, timestamp: timestamp)
            let fileURL = self.cacheDir.appendingPathComponent(key)
            try? data.write(to: fileURL, options: .atomic)
            
            if self.estimatedCacheSize >= 0 {
                self.estimatedCacheSize += Int64(data.count)
            }
            self.saveCountSinceLastCheck += 1
            
            // 节流机制：每 50 次写入或预估容量超标时才触发真实物理扫描
            if self.saveCountSinceLastCheck >= 50 || (self.estimatedCacheSize > Self.maxThumbnailCacheSize) {
                self.saveCountSinceLastCheck = 0
                self.cleanupCacheIfNeeded()
            }
        }
    }
    
    public func invalidate(fileId: String) {
        queue.async(flags: .barrier) {
            self.estimatedCacheSize = -1
            let safeId = fileId.replacingOccurrences(of: "/", with: "_")
                               .replacingOccurrences(of: ":", with: "_")
            let fm = FileManager.default
            if let files = try? fm.contentsOfDirectory(atPath: self.cacheDir.path) {
                let targetPrefix = "\(safeId)_"
                for file in files where file.hasPrefix(targetPrefix) {
                    let remainder = file.dropFirst(targetPrefix.count)
                    if remainder.first?.isNumber == true {
                        try? fm.removeItem(at: self.cacheDir.appendingPathComponent(file))
                    }
                }
            }
        }
    }
    
    public func clearAllCache() {
        queue.async(flags: .barrier) {
            self.estimatedCacheSize = 0
            self.saveCountSinceLastCheck = 0
            let fm = FileManager.default
            if let files = try? fm.contentsOfDirectory(atPath: self.cacheDir.path) {
                for file in files {
                    try? fm.removeItem(at: self.cacheDir.appendingPathComponent(file))
                }
            }
        }
    }
    
    public func currentCacheSize() -> Int64 {
        var total: Int64 = 0
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(atPath: cacheDir.path) {
            for file in files {
                let path = cacheDir.appendingPathComponent(file).path
                if let attrs = try? fm.attributesOfItem(atPath: path),
                   let size = attrs[.size] as? Int64 {
                    total += size
                }
            }
        }
        estimatedCacheSize = total
        return total
    }
    
    private func cleanupCacheIfNeeded() {
        let current = currentCacheSize()
        guard current > Self.maxThumbnailCacheSize else { return }
        
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: cacheDir.path) else { return }
        
        // 按最后修改时间排序，移除最旧的 30% 文件
        var fileList: [(url: URL, date: Date, size: Int64)] = []
        for file in files {
            let url = cacheDir.appendingPathComponent(file)
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let date = attrs[.modificationDate] as? Date,
               let size = attrs[.size] as? Int64 {
                fileList.append((url, date, size))
            }
        }
        
        fileList.sort { $0.date < $1.date }
        
        var reclaimed: Int64 = 0
        let targetReclaim = current - Int64(Double(Self.maxThumbnailCacheSize) * 0.7)
        for item in fileList {
            if reclaimed >= targetReclaim { break }
            try? fm.removeItem(at: item.url)
            reclaimed += item.size
        }
    }
    
    // MARK: - 辅助压缩工具
    
    private func compressCGImageToJPEG(cgImage: CGImage, quality: CGFloat = 0.75) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        
        return data as Data
    }
}
