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

    func withPublicationLease<Result>(fileId: String, _ body: () throws -> Result) throws -> Result {
        let directory = storage.cacheDirectory.deletingLastPathComponent().appendingPathComponent("leases", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = SHA256.hash(data: Data(accessKey(fileId).utf8)).map { String(format: "%02x", $0) }.joined()
        let descriptor = open(directory.appendingPathComponent(name + ".publish.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        var result: Int32
        repeat { result = flock(descriptor, LOCK_EX) } while result != 0 && errno == EINTR
        guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    func withPublicationLeases<Result>(fileIds: [String], _ body: () throws -> Result) throws -> Result {
        let keys = Array(Set(fileIds.map { accessKey($0) })).sorted()
        func acquire(_ index: Int) throws -> Result {
            if index == keys.count { return try body() }
            return try withPublicationLease(fileId: keys[index]) { try acquire(index + 1) }
        }
        return try acquire(0)
    }

    func withEvictionLease(fileId: String, _ body: () throws -> Void) throws -> Bool {
        // Keep the same lock order as writers: journal, then content lease.
        try syncManager.withJournalCommit {
            let descriptor = leaseDescriptor(fileId: fileId)
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
            defer { _ = flock(descriptor, LOCK_UN) }
            guard !isProtected(fileId: fileId) else { return false }
            try body()
            try markEvictedIfClean(fileId: fileId)
            return true
        }
    }

    func markEvictedIfClean(fileId: String) throws {
        if !storage.exists(fileId: fileId) { try? contentIndex.remove(fileId) }
        guard !storage.exists(fileId: fileId),
              var metadata = try syncManager.getMetadataPersistent(fileId: fileId),
              metadata.syncStatus == .synced else { return }
        metadata.syncStatus = .cloudOnly
        metadata.downloadProgress = 0
        try syncManager.updateMetadataPersistent(metadata)
    }

    public func beginAccess(fileId: String) {
        // Never block on flock while holding accessLock: eviction checks the
        // in-process access count while it owns the exclusive content lease.
        let descriptor = leaseDescriptor(fileId: fileId)
        let acquired = descriptor >= 0 && flock(descriptor, LOCK_SH) == 0
        accessLock.lock(); defer { accessLock.unlock() }
        let key = accessKey(fileId)
        if activeAccesses[key, default: 0] == 0, acquired {
            accessDescriptors[key] = descriptor
        } else if descriptor >= 0 {
            if acquired { _ = flock(descriptor, LOCK_UN) }
            close(descriptor)
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
        guard metadataStore.isHealthy else { return true }
        let normalizedId = fileId.hasPrefix("/") ? fileId : "/" + fileId
        let strippedId = fileId.hasPrefix("/") ? String(fileId.dropFirst()) : fileId
        
        accessLock.lock()
        let inUse = (activeAccesses[accessKey(normalizedId), default: 0] > 0) || (activeAccesses[accessKey(strippedId), default: 0] > 0)
        accessLock.unlock()
        if inUse || effectivePolicy(fileId: normalizedId) == .pinned || effectivePolicy(fileId: strippedId) == .pinned { return true }
        if syncManager.hasPendingOperation(fileId: normalizedId) || syncManager.hasPendingUpload(fileId: normalizedId) ||
           syncManager.hasPendingOperation(fileId: strippedId) || syncManager.hasPendingUpload(fileId: strippedId) { return true }
        guard metadataStore.isHealthy else { return true }
        let status: SyncStatus?
        do { status = try syncManager.getMetadataPersistent(fileId: normalizedId)?.syncStatus }
        catch { return true }
        guard let status else { return false }
        // Only a confirmed clean remote replica can be discarded.
        return status != .synced && status != .cloudOnly
    }
}
