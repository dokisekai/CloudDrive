//
//  ThumbnailCatalog.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  目录级单一清单包 (.thumbnails.catalog) 紧凑二进制格式定义与编解码器
//

import Foundation

public struct ThumbnailCatalogEntry: Sendable {
    public let filename: String
    public let fileId: String
    public var offset: UInt64
    public var length: UInt32
    public var timestamp: Int64
    public var width: UInt16
    public var height: UInt16
    
    public init(filename: String, fileId: String, offset: UInt64, length: UInt32, timestamp: Int64, width: UInt16, height: UInt16) {
        self.filename = filename
        self.fileId = fileId
        self.offset = offset
        self.length = length
        self.timestamp = timestamp
        self.width = width
        self.height = height
    }
}

public final class ThumbnailCatalog: @unchecked Sendable {
    public static let catalogFileName = ".thumbnails.catalog"
    public static let magicHeader: [UInt8] = [0x43, 0x44, 0x54, 0x48] // "CDTH"
    public static let magicTrailer: [UInt8] = [0x48, 0x54, 0x44, 0x43] // "HTDC"
    public static let currentVersion: UInt16 = 1
    
    private let lock = NSLock()
    private var entries: [String: ThumbnailCatalogEntry] = [:] // key: filename
    private var entriesByFileId: [String: String] = [:]       // fileId -> filename
    private var payloadData: Data = Data()
    
    public init() {}
    
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
    
    public var totalPayloadSize: Int {
        lock.lock()
        defer { lock.unlock() }
        return payloadData.count
    }
    
    // MARK: - 查询缩略图数据 (毫秒级切片)
    
    public func getImageData(forFilename filename: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        
        guard let entry = entries[filename] else { return nil }
        let start = Int(entry.offset)
        let end = start + Int(entry.length)
        guard start >= 0, end <= payloadData.count else { return nil }
        
        return payloadData.subdata(in: start..<end)
    }
    
    public func getImageData(forFileId fileId: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        
        guard let filename = entriesByFileId[fileId] else { return nil }
        guard let entry = entries[filename] else { return nil }
        let start = Int(entry.offset)
        let end = start + Int(entry.length)
        guard start >= 0, end <= payloadData.count else { return nil }
        
        return payloadData.subdata(in: start..<end)
    }
    
    public func getEntry(forFilename filename: String) -> ThumbnailCatalogEntry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[filename]
    }
    
    public func getEntry(forFileId fileId: String) -> ThumbnailCatalogEntry? {
        lock.lock()
        defer { lock.unlock() }
        guard let fn = entriesByFileId[fileId] else { return nil }
        return entries[fn]
    }
    
    /// 合并另一个清单包（增量保留最新时间戳条目）
    public func merge(with other: ThumbnailCatalog) {
        lock.lock()
        other.lock.lock()
        defer {
            other.lock.unlock()
            lock.unlock()
        }
        
        for (filename, otherEntry) in other.entries {
            let start = Int(otherEntry.offset)
            let end = start + Int(otherEntry.length)
            guard start >= 0, end <= other.payloadData.count else { continue }
            let otherImgData = other.payloadData.subdata(in: start..<end)
            
            if let myEntry = self.entries[filename] {
                // 如果对方的时间戳更新，则用对方的覆盖
                if otherEntry.timestamp > myEntry.timestamp {
                    let offset = UInt64(self.payloadData.count)
                    self.payloadData.append(otherImgData)
                    var updated = otherEntry
                    updated.offset = offset
                    self.entries[filename] = updated
                    self.entriesByFileId[otherEntry.fileId] = filename
                }
            } else {
                // 本地不存在该条目，追加合并
                let offset = UInt64(self.payloadData.count)
                self.payloadData.append(otherImgData)
                var newEntry = otherEntry
                newEntry.offset = offset
                self.entries[filename] = newEntry
                self.entriesByFileId[otherEntry.fileId] = filename
            }
        }
    }
    
    // MARK: - 添加或更新条目 (追加写入模式)
    
    public func addOrUpdate(filename: String, fileId: String, imageData: Data, timestamp: Int64, width: Int, height: Int) {
        lock.lock()
        defer { lock.unlock() }
        
        let offset = UInt64(payloadData.count)
        let length = UInt32(imageData.count)
        
        // 将新图片直接追加到尾部
        payloadData.append(imageData)
        
        let entry = ThumbnailCatalogEntry(
            filename: filename,
            fileId: fileId,
            offset: offset,
            length: length,
            timestamp: timestamp,
            width: UInt16(min(max(width, 1), 65535)),
            height: UInt16(min(max(height, 1), 65535))
        )
        
        entries[filename] = entry
        entriesByFileId[fileId] = filename
    }
    
    public func remove(filename: String) {
        lock.lock()
        defer { lock.unlock() }
        
        if let entry = entries.removeValue(forKey: filename) {
            entriesByFileId.removeValue(forKey: entry.fileId)
        }
        compactIfNeededLocked()
    }
    
    public func remove(fileId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        if let fn = entriesByFileId.removeValue(forKey: fileId) {
            entries.removeValue(forKey: fn)
        }
        compactIfNeededLocked()
    }
    
    public func compactIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        compactIfNeededLocked()
    }
    
    private func compactIfNeededLocked() {
        let activeBytes = entries.values.reduce(0) { $0 + Int($1.length) }
        // 若活跃字节小于总负载的 65% 且总负载大于 32KB，则触发压缩重整
        if payloadData.count > 32 * 1024 && activeBytes < (payloadData.count * 65 / 100) {
            var newPayload = Data()
            for (filename, var entry) in entries {
                let start = Int(entry.offset)
                let end = start + Int(entry.length)
                guard start >= 0, end <= payloadData.count else { continue }
                let slice = payloadData.subdata(in: start..<end)
                entry.offset = UInt64(newPayload.count)
                newPayload.append(slice)
                entries[filename] = entry
            }
            payloadData = newPayload
        }
    }
    
    // MARK: - 二进制序列化 (Serialize)
    
    public func serialize() -> Data {
        lock.lock()
        defer { lock.unlock() }
        
        var data = Data()
        
        // 1. Header (固定 32 字节)
        data.append(contentsOf: Self.magicHeader)                     // 4 bytes: CDTH
        data.append(contentsOf: Self.currentVersion.bytes)             // 2 bytes: Version = 1
        data.append(contentsOf: UInt16(0).bytes)                       // 2 bytes: Reserved
        let entryCount = UInt32(entries.count)
        data.append(contentsOf: entryCount.bytes)                      // 4 bytes: Count
        
        let indexOffset = UInt64(32 + payloadData.count)
        data.append(contentsOf: indexOffset.bytes)                     // 8 bytes: Index Table Offset
        data.append(contentsOf: [UInt8](repeating: 0, count: 12))      // 12 bytes: Padding to 32 bytes
        
        // 2. Payload Data (连续图像字节流)
        data.append(payloadData)
        
        // 3. Index Table (尾部索引表)
        for (_, entry) in entries {
            let fnBytes = [UInt8](entry.filename.utf8)
            let fidBytes = [UInt8](entry.fileId.utf8)
            
            data.append(contentsOf: UInt16(fnBytes.count).bytes)
            data.append(contentsOf: fnBytes)
            
            data.append(contentsOf: UInt16(fidBytes.count).bytes)
            data.append(contentsOf: fidBytes)
            
            data.append(contentsOf: entry.offset.bytes)
            data.append(contentsOf: entry.length.bytes)
            data.append(contentsOf: entry.timestamp.bytes)
            data.append(contentsOf: entry.width.bytes)
            data.append(contentsOf: entry.height.bytes)
        }
        
        // 4. Trailer (16 字节)
        data.append(contentsOf: [UInt8](repeating: 0, count: 12))      // 12 bytes: Reserved/Checksum
        data.append(contentsOf: Self.magicTrailer)                     // 4 bytes: HTDC
        
        return data
    }
    
    // MARK: - 二进制反序列化 (Deserialize)
    
    public static func deserialize(from data: Data) -> ThumbnailCatalog? {
        guard data.count >= 48 else { return nil } // 32 Header + 16 Trailer
        
        // 1. 验证 Magic Header
        let headerMagic = [UInt8](data.subdata(in: 0..<4))
        guard headerMagic == Self.magicHeader else { return nil }
        
        // 2. 验证 Magic Trailer
        let trailerMagic = [UInt8](data.subdata(in: (data.count - 4)..<data.count))
        guard trailerMagic == Self.magicTrailer else { return nil }
        
        // 3. 解析 Header
        let version = data.readUInt16(at: 4)
        guard version == Self.currentVersion else { return nil }
        
        let count = Int(data.readUInt32(at: 8))
        let indexOffset = Int(data.readUInt64(at: 12))
        guard indexOffset >= 32 && indexOffset <= data.count - 16 else { return nil }
        
        let catalog = ThumbnailCatalog()
        let payloadLen = indexOffset - 32
        if payloadLen > 0 {
            catalog.payloadData = data.subdata(in: 32..<indexOffset)
        }
        
        // 4. 解析 Index Table
        var readPtr = indexOffset
        for _ in 0..<count {
            guard readPtr + 2 <= data.count - 16 else { break }
            let fnLen = Int(data.readUInt16(at: readPtr))
            readPtr += 2
            
            guard readPtr + fnLen <= data.count - 16 else { break }
            guard let fn = String(data: data.subdata(in: readPtr..<(readPtr + fnLen)), encoding: .utf8) else { break }
            readPtr += fnLen
            
            guard readPtr + 2 <= data.count - 16 else { break }
            let fidLen = Int(data.readUInt16(at: readPtr))
            readPtr += 2
            
            guard readPtr + fidLen <= data.count - 16 else { break }
            guard let fid = String(data: data.subdata(in: readPtr..<(readPtr + fidLen)), encoding: .utf8) else { break }
            readPtr += fidLen
            
            guard readPtr + 24 <= data.count - 16 else { break }
            let offset = data.readUInt64(at: readPtr)
            let length = data.readUInt32(at: readPtr + 8)
            let timestamp = data.readInt64(at: readPtr + 12)
            let width = data.readUInt16(at: readPtr + 20)
            let height = data.readUInt16(at: readPtr + 22)
            readPtr += 24
            
            let entry = ThumbnailCatalogEntry(
                filename: fn,
                fileId: fid,
                offset: offset,
                length: length,
                timestamp: timestamp,
                width: width,
                height: height
            )
            catalog.entries[fn] = entry
            catalog.entriesByFileId[fid] = fn
        }
        
        return catalog
    }
}

// MARK: - 辅助字节序拓展

private extension FixedWidthInteger {
    var bytes: [UInt8] {
        withUnsafeBytes(of: self.littleEndian) { Array($0) }
    }
}

private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        let sub = self.subdata(in: offset..<(offset + 2))
        return sub.withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
    }
    
    func readUInt32(at offset: Int) -> UInt32 {
        let sub = self.subdata(in: offset..<(offset + 4))
        return sub.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    }
    
    func readUInt64(at offset: Int) -> UInt64 {
        let sub = self.subdata(in: offset..<(offset + 8))
        return sub.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
    }
    
    func readInt64(at offset: Int) -> Int64 {
        let sub = self.subdata(in: offset..<(offset + 8))
        return sub.withUnsafeBytes { $0.load(as: Int64.self).littleEndian }
    }
}
