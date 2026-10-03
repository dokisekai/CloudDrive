//
//  CacheService.swift
//  CloudDriveCache
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  缓存统一门面服务 (Cache Facade)
//

import Foundation
import CloudDriveContracts
import Darwin
import CryptoKit

extension CacheService {
    func accessKey(_ id: String) -> String { id.hasPrefix("/") ? String(id.dropFirst()) : id }

    func leaseDescriptor(fileId: String) -> Int32 {
        let directory = storage.cacheDirectory.deletingLastPathComponent().appendingPathComponent("leases", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = SHA256.hash(data: Data(accessKey(fileId).utf8)).map { String(format: "%02x", $0) }.joined()
        return open(directory.appendingPathComponent(name + ".lock").path, O_CREAT | O_RDWR, 0o600)
    }

    func withEvictionLease(fileId: String, _ body: () throws -> Void) throws -> Bool {
        let descriptor = leaseDescriptor(fileId: fileId)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        defer { _ = flock(descriptor, LOCK_UN) }
        try body()
        return true
    }

    public func beginAccess(fileId: String) {
        accessLock.lock(); defer { accessLock.unlock() }
        let key = accessKey(fileId)
        if activeAccesses[key, default: 0] == 0 {
            let descriptor = leaseDescriptor(fileId: fileId)
            if descriptor >= 0 { _ = flock(descriptor, LOCK_SH); accessDescriptors[key] = descriptor }
        }
        activeAccesses[key, default: 0] += 1
    }

    public func endAccess(fileId: String) {
        accessLock.lock(); defer { accessLock.unlock() }
        let key = accessKey(fileId)
        if let count = activeAccesses[key], count > 1 { activeAccesses[key] = count - 1 }
        else {
            activeAccesses.removeValue(forKey: key)
            if let descriptor = accessDescriptors.removeValue(forKey: key) { _ = flock(descriptor, LOCK_UN); close(descriptor) }
        }
    }

    func isProtected(fileId: String) -> Bool {
        let normalizedId = fileId.hasPrefix("/") ? fileId : "/" + fileId
        let strippedId = fileId.hasPrefix("/") ? String(fileId.dropFirst()) : fileId
        
        accessLock.lock()
        let inUse = (activeAccesses[accessKey(normalizedId), default: 0] > 0) || (activeAccesses[accessKey(strippedId), default: 0] > 0)
        accessLock.unlock()
        if inUse || effectivePolicy(fileId: normalizedId) == .pinned || effectivePolicy(fileId: strippedId) == .pinned { return true }
        if syncManager.hasPendingOperation(fileId: normalizedId) || syncManager.hasPendingUpload(fileId: normalizedId) ||
           syncManager.hasPendingOperation(fileId: strippedId) || syncManager.hasPendingUpload(fileId: strippedId) { return true }
        let status = syncManager.getMetadata(fileId: normalizedId)?.syncStatus ?? syncManager.getMetadata(fileId: strippedId)?.syncStatus
        guard let status = status else { return false }
        // Only a confirmed clean remote replica can be discarded.
        return status != .synced && status != .cloudOnly
    }
}
