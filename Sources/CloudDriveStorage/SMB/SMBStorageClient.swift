//
//  SMBStorageClient.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  SMB / CIFS / Windows 局域网共享存储客户端 (基于 macOS NetFS 原生内核挂载与 POSIX 文件系统)
//

import Foundation
import CloudDriveContracts
import CloudDriveSupport
import NetFS
import UniformTypeIdentifiers
import CryptoKit

/// SMB 协议存储客户端
public class SMBStorageClient: StorageClient {
    public let config: SMBStorageConfig
    let fileManager = FileManager.default
    private var cachedMountPath: String?
    
    public init(config: SMBStorageConfig) {
        self.config = config
    }
    
    // MARK: - Mount Management
    
    private func isVolumeMatching(url: URL, host: String, share: String) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.volumeURLForRemountingKey, .volumeNameKey]) else {
            return false
        }
        if let remountURL = values.volumeURLForRemounting {
            if let remountHost = remountURL.host,
               remountHost.caseInsensitiveCompare(host) == .orderedSame {
                let remountShare = remountURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if remountShare.caseInsensitiveCompare(share) == .orderedSame {
                    return true
                }
            }
        }
        return false
    }

    private func findMountedVolume(host: String, share: String) -> String? {
        let volumesURL = URL(fileURLWithPath: "/Volumes")
        guard let items = try? fileManager.contentsOfDirectory(at: volumesURL, includingPropertiesForKeys: [.volumeURLForRemountingKey, .volumeNameKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        for item in items {
            if isVolumeMatching(url: item, host: host, share: share) {
                return item.path
            }
        }
        return nil
    }

    /// 确保 SMB 共享已被挂载，并返回挂载点本地绝对路径
    public func ensureMounted() throws -> String {
        if let cached = cachedMountPath, fileManager.fileExists(atPath: cached) {
            return cached
        }
        
        let cleanShare = config.share.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        
        // 1. 优先通过系统已挂载卷列表检查是否已有匹配主机与共享名的挂载点
        if let matched = findMountedVolume(host: config.host, share: cleanShare) {
            self.cachedMountPath = matched
            return matched
        }
        
        // 2. 调用 macOS 原生 NetFSMountURLSync 挂载
        guard let smbURL = config.fullSMBURL else {
            throw StorageError.invalidOperation
        }
        
        let userCF = config.username.isEmpty ? nil : (config.username as CFString)
        let passCF = config.password.isEmpty ? nil : (config.password as CFString)
        
        var mountpoints: Unmanaged<CFArray>?
        let status = NetFSMountURLSync(
            smbURL as CFURL,
            nil,
            userCF,
            passCF,
            nil,
            nil,
            &mountpoints
        )
        
        // 0: 成功挂载
        if status == 0, let unmanagedArray = mountpoints {
            let array = unmanagedArray.takeRetainedValue() as? [String]
            if let firstMount = array?.first, fileManager.fileExists(atPath: firstMount) {
                self.cachedMountPath = firstMount
                return firstMount
            }
        }
        
        // 17 (EEXIST) 或 16 (EBUSY): 已挂载，重新扫描确认
        if status == 17 || status == 16 || status == 0 {
            if let matched = findMountedVolume(host: config.host, share: cleanShare) {
                self.cachedMountPath = matched
                return matched
            }
            let defaultVolumePath = "/Volumes/\(cleanShare)"
            if fileManager.fileExists(atPath: defaultVolumePath) {
                let volURL = URL(fileURLWithPath: defaultVolumePath)
                if let remountHost = (try? volURL.resourceValues(forKeys: [.volumeURLForRemountingKey]))?.volumeURLForRemounting?.host {
                    if remountHost.caseInsensitiveCompare(config.host) != .orderedSame {
                        throw StorageError.networkError("卷名冲突：\(defaultVolumePath) 属于 \(remountHost)，非目标主机 \(config.host)")
                    }
                }
                self.cachedMountPath = defaultVolumePath
                return defaultVolumePath
            }
        }
        
        // 如果返回权限错误
        if status == 13 || status == 80 { // EACCES or auth failure
            throw StorageError.authenticationFailed
        }
        
        throw StorageError.networkError("无法挂载 SMB 共享 [\(config.displayURL)], 错误码: \(status)")
    }
    
    /// 将 VFS 逻辑路径映射为本地挂载点绝对 URL
}
