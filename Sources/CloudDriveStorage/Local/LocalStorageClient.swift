//
//  LocalStorageClient.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  本地文件夹存储客户端 (支持 macOS 沙箱安全书签访问)
//

import Foundation
import CloudDriveContracts
import CloudDriveSupport
import UniformTypeIdentifiers

/// 本地存储客户端，实现 StorageClient 协议
public class LocalStorageClient: StorageClient {
    public static let shared = LocalStorageClient()
    
    let fileManager = FileManager.default
    private(set) var securityScopedURL: URL?
    private(set) var isAccessingSecurityScope = false
    
    public init() {}
    
    public convenience init(rootPath: String) {
        self.init()
        self.configureSecurityScope(url: URL(fileURLWithPath: rootPath))
    }
    
    /// 配置安全范围访问（支持安全书签与直接 URL）
    public func configureSecurityScope(url: URL? = nil, bookmarkData: Data? = nil) {
        // 停止之前的访问
        cleanupSecurityScope()
        
        // 1. 优先使用安全书签解析（跨进程/沙箱扩展必需）
        if let data = bookmarkData {
            var isStale = false
            do {
                let resolvedURL = try URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                let success = resolvedURL.startAccessingSecurityScopedResource()
                self.securityScopedURL = resolvedURL
                self.isAccessingSecurityScope = success
                logInfo(.system, "🔐 LocalStorage: Security scope access via bookmark: \(resolvedURL.path), success: \(success), isStale: \(isStale)")
                if success {
                    return
                }
            } catch {
                logError(.system, "⚠️ LocalStorage: Failed to resolve security bookmark: \(error.localizedDescription)")
            }
        }
        
        // 2. 回退到直接请求 URL 范围
        if let targetURL = url {
            let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            if targetURL.path.hasPrefix(documentsDir.path) {
                securityScopedURL = targetURL
                isAccessingSecurityScope = true
                logInfo(.system, "🔐 LocalStorage: URL is within Documents directory, skipping security scope: \(targetURL.path)")
            } else {
                securityScopedURL = targetURL
                isAccessingSecurityScope = targetURL.startAccessingSecurityScopedResource()
                logInfo(.system, "🔐 LocalStorage: Direct URL security scope access: \(isAccessingSecurityScope), target: \(targetURL.path)")
            }
        }
    }
    
    /// 清理安全范围访问
    public func cleanupSecurityScope() {
        if isAccessingSecurityScope, let url = securityScopedURL {
            url.stopAccessingSecurityScopedResource()
            isAccessingSecurityScope = false
            logInfo(.system, "🔐 LocalStorage: Stopped security-scoped resource access")
        }
        securityScopedURL = nil
    }
    
    deinit {
        cleanupSecurityScope()
    }
}
