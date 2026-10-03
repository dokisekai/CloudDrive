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
import CloudDriveSupport
import Darwin
import CryptoKit

extension CacheService {
    public func effectivePolicy(fileId: String) -> CachePolicy {
        if let policy = metadataStore.get(for: fileId)?.policy, policy != .automatic { return policy }
        var parent = (fileId as NSString).deletingLastPathComponent
        while !parent.isEmpty && parent != "/" {
            if metadataStore.get(for: parent)?.policy == .pinned { return .pinned }
            parent = (parent as NSString).deletingLastPathComponent
        }
        return metadataStore.get(for: "ROOT")?.policy == .pinned ? .pinned : .automatic
    }

    public func setCachePolicy(fileId: String, policy: CachePolicy) {
        metadataStore.setPolicy(for: fileId, policy: policy)
        metadataStore.save(immediate: true)
        Logger.shared.info(.cache, "Set cache policy: \(fileId) -> \(policy.rawValue)")
    }

    public func getAllPinnedFileIds() -> [String] {
        metadataStore.getAllPinnedFileIds()
    }

    public func pinFile(fileId: String) {
        setCachePolicy(fileId: fileId, policy: .pinned)
        notifier.postPolicyNotification(fileId: fileId)
    }

    public func unpinFile(fileId: String) {
        setCachePolicy(fileId: fileId, policy: .automatic)
        notifier.postPolicyNotification(fileId: fileId)
    }
}
