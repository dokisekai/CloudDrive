import CloudDriveContracts
import CloudDriveSupport
//
//  SecurityScopedBookmarkHandler.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  macOS 安全作用域书签处理器 (用于跨进程、跨沙箱访问外部持久化目录)
//

import Foundation

public struct SecurityScopedBookmarkHandler: Sendable {
    
    /// 从用户选择的本地目录 URL 生成持久化安全书签
    public static func createBookmark(for url: URL) throws -> Data {
        #if os(macOS)
        return try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #else
        return try url.bookmarkData(
            options: .suitableForBookmarkFile,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #endif
    }
    
    /// 解析已持久化的安全书签并返回访问路径及是否已过期
    public static func resolveBookmark(data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        #if os(macOS)
        let resolvedURL = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        #else
        let resolvedURL = try URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        #endif
        return (resolvedURL, isStale)
    }
    
    /// 在安全作用域保护上下文内执行操作，并确保退出时自动释放作用域
    public static func withSecurityScope<T>(for data: Data, block: (URL) throws -> T) throws -> T {
        let (resolvedURL, _) = try resolveBookmark(data: data)
        let didStartAccess = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }
        return try block(resolvedURL)
    }
}
