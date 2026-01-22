//
//  StorageClient.swift
//  CloudDriveCore
//
//  存储客户端协议 - 统一本地和WebDAV存储接口
//

import Foundation

// MARK: - Storage Client Protocol

/// 存储客户端协议，统一本地和WebDAV存储接口
public protocol StorageClient {
    /// 列出目录内容
    func listDirectory(path: String) async throws -> [StorageResource]
    
    /// 下载文件
    func downloadFile(path: String, to destinationURL: URL, progress: @escaping (Double) -> Void) async throws
    
    /// 上传文件
    func uploadFile(localURL: URL, to remotePath: String, progress: @escaping (Double) -> Void) async throws
    
    /// 创建目录
    func createDirectory(path: String) async throws
    
    /// 删除文件或目录
    func delete(path: String) async throws
    
    /// 移动/重命名
    func move(from sourcePath: String, to destinationPath: String) async throws
    
    /// 检查路径是否存在
    func exists(path: String) async throws -> Bool
}

// MARK: - Storage Resource

/// 存储资源模型
public struct StorageResource {
    public let path: String
    public let displayName: String
    public let isDirectory: Bool
    public let contentLength: Int64
    public let contentType: String?
    public let creationDate: Date?
    public let lastModified: Date?
    public let etag: String?
    
    public init(path: String, displayName: String, isDirectory: Bool, contentLength: Int64,
                contentType: String?, creationDate: Date?, lastModified: Date?, etag: String?) {
        self.path = path
        self.displayName = displayName
        self.isDirectory = isDirectory
        self.contentLength = contentLength
        self.contentType = contentType
        self.creationDate = creationDate
        self.lastModified = lastModified
        self.etag = etag
    }
}

// MARK: - Local Storage Client

/// 本地存储客户端，实现StorageClient协议
public class LocalStorageClient: StorageClient {
    public static let shared = LocalStorageClient()
    
    private let fileManager = FileManager.default
    private var securityScopedURL: URL?
    private var isAccessingSecurityScope = false
    
    public init() {
    }
    
    /// 配置安全范围URL（用于沙箱访问）
    public func configureSecurityScope(url: URL) {
        print("🔐 LocalStorage: 配置安全范围URL: \(url.path)")
        
        // 停止之前的访问
        if isAccessingSecurityScope, let oldURL = securityScopedURL {
            oldURL.stopAccessingSecurityScopedResource()
            isAccessingSecurityScope = false
        }
        
        // 检查URL是否在Documents目录下，Documents目录下的文件无需安全范围访问
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let isInDocuments = url.path.hasPrefix(documentsDir.path)
        
        if isInDocuments {
            // Documents目录下的文件无需安全范围访问
            securityScopedURL = url
            isAccessingSecurityScope = true
            print("🔐 LocalStorage: URL在Documents目录下，无需安全范围访问")
        } else {
            // 其他目录需要安全范围访问
            securityScopedURL = url
            isAccessingSecurityScope = url.startAccessingSecurityScopedResource()
            print("🔐 LocalStorage: 安全范围访问状态: \(isAccessingSecurityScope)")
        }
    }
    
    /// 清理安全范围访问
    public func cleanupSecurityScope() {
        if isAccessingSecurityScope, let url = securityScopedURL {
            url.stopAccessingSecurityScopedResource()
            isAccessingSecurityScope = false
            print("🔐 LocalStorage: 已停止安全范围访问")
        }
        securityScopedURL = nil
    }
    
    deinit {
        cleanupSecurityScope()
    }
    
    /// 检查路径是否存在
    public func exists(path: String) async throws -> Bool {
        let url = URL(fileURLWithPath: path)
        
        // 如果有安全范围URL，确保操作在安全范围内进行
        if let securityURL = securityScopedURL, isAccessingSecurityScope {
            // 检查路径是否在安全范围内
            if url.path.hasPrefix(securityURL.path) {
                return fileManager.fileExists(atPath: path)
            }
        }
        
        // 直接使用安全范围访问
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        
        return fileManager.fileExists(atPath: path)
    }
    
    /// 列出目录内容
    public func listDirectory(path: String) async throws -> [StorageResource] {
        let url = URL(fileURLWithPath: path)
        
        // 处理安全范围访问
        var hasAccess = false
        if let securityURL = securityScopedURL, isAccessingSecurityScope {
            if url.path.hasPrefix(securityURL.path) {
                // 已经在安全范围内，可以直接访问
            } else {
                hasAccess = url.startAccessingSecurityScopedResource()
            }
        } else {
            hasAccess = url.startAccessingSecurityScopedResource()
        }
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        
        guard fileManager.fileExists(atPath: path, isDirectory: nil) else {
            throw StorageError.notFound
        }
        
        let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [
            .nameKey,
            .isDirectoryKey,
            .fileSizeKey,
            .contentTypeKey,
            .creationDateKey,
            .contentModificationDateKey
        ])
        
        var resources: [StorageResource] = []
        
        for contentURL in contents {
            let resourceValues = try contentURL.resourceValues(forKeys: [
                .nameKey,
                .isDirectoryKey,
                .fileSizeKey,
                .contentTypeKey,
                .creationDateKey,
                .contentModificationDateKey
            ])
            
            let isDirectory = resourceValues.isDirectory ?? false
            let size = isDirectory ? 0 : (resourceValues.fileSize ?? 0)
            let displayName = resourceValues.name ?? contentURL.lastPathComponent
            
            let resource = StorageResource(
                path: contentURL.path,
                displayName: displayName,
                isDirectory: isDirectory,
                contentLength: Int64(size),
                contentType: resourceValues.contentType?.identifier,
                creationDate: resourceValues.creationDate,
                lastModified: resourceValues.contentModificationDate,
                etag: nil // 本地文件没有etag
            )
            
            resources.append(resource)
        }
        
        return resources
    }
    
    /// 下载文件 - 本地存储直接复制
    public func downloadFile(path: String, to destinationURL: URL, progress: @escaping (Double) -> Void) async throws {
        let sourceURL = URL(fileURLWithPath: path)
        
        // 处理安全范围访问
        var hasAccess = false
        if let securityURL = securityScopedURL, isAccessingSecurityScope {
            if sourceURL.path.hasPrefix(securityURL.path) {
                // 已经在安全范围内，可以直接访问
            } else {
                hasAccess = sourceURL.startAccessingSecurityScopedResource()
            }
        } else {
            hasAccess = sourceURL.startAccessingSecurityScopedResource()
        }
        defer { if hasAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        
        guard fileManager.fileExists(atPath: path) else {
            throw StorageError.notFound
        }
        
        // 确保目标目录存在
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        
        // 删除已存在的目标文件
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        
        // 复制文件
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        
        // 报告进度
        progress(1.0)
    }
    
    /// 上传文件 - 本地存储直接复制
    public func uploadFile(localURL: URL, to remotePath: String, progress: @escaping (Double) -> Void) async throws {
        let destinationURL = URL(fileURLWithPath: remotePath)
        
        print("📤 LocalStorage: 上传文件")
        print("   源: \(localURL.path)")
        print("   目标: \(remotePath)")
        
        // 处理源文件安全范围访问
        let hasLocalAccess = localURL.startAccessingSecurityScopedResource()
        defer { if hasLocalAccess { localURL.stopAccessingSecurityScopedResource() } }
        
        // 处理目标文件安全范围访问
        var hasDestinationAccess = false
        let destinationParent = destinationURL.deletingLastPathComponent()
        
        if let securityURL = securityScopedURL, isAccessingSecurityScope {
            if destinationURL.path.hasPrefix(securityURL.path) {
                // 已经在安全范围内，可以直接访问
                print("🔐 LocalStorage: 目标在安全范围内")
            } else {
                hasDestinationAccess = destinationParent.startAccessingSecurityScopedResource()
                print("🔐 LocalStorage: 启动父目录安全范围访问: \(hasDestinationAccess)")
            }
        } else {
            hasDestinationAccess = destinationParent.startAccessingSecurityScopedResource()
            print("🔐 LocalStorage: 启动父目录安全范围访问: \(hasDestinationAccess)")
        }
        defer { if hasDestinationAccess { destinationParent.stopAccessingSecurityScopedResource() } }
        
        // 确保目标目录存在
        if !fileManager.fileExists(atPath: destinationParent.path) {
            print("📁 LocalStorage: 创建父目录: \(destinationParent.path)")
            do {
                try fileManager.createDirectory(at: destinationParent, withIntermediateDirectories: true, attributes: nil)
                print("✅ LocalStorage: 父目录创建成功")
            } catch {
                print("❌ LocalStorage: 父目录创建失败: \(error)")
                throw StorageError.fileSystemError(error)
            }
        }
        
        // 删除已存在的目标文件
        if fileManager.fileExists(atPath: destinationURL.path) {
            print("🗑️ LocalStorage: 删除已存在的文件")
            do {
                try fileManager.removeItem(at: destinationURL)
            } catch {
                print("⚠️ LocalStorage: 删除已存在文件失败: \(error)")
            }
        }
        
        // 读取并写入文件（更可靠的方式）
        do {
            print("📖 LocalStorage: 读取源文件...")
            let fileData = try Data(contentsOf: localURL)
            print("📊 LocalStorage: 读取文件数据: \(fileData.count) 字节")
            
            print("💾 LocalStorage: 写入目标文件...")
            try fileData.write(to: destinationURL, options: [.atomic])
            print("✅ LocalStorage: 文件写入成功")
            
            // 验证文件是否真的写入成功
            if fileManager.fileExists(atPath: destinationURL.path) {
                let attributes = try fileManager.attributesOfItem(atPath: destinationURL.path)
                let fileSize = attributes[.size] as? Int64 ?? 0
                print("✅ LocalStorage: 文件验证成功，大小: \(fileSize) 字节")
                
                if fileSize != fileData.count {
                    print("⚠️ LocalStorage: 文件大小不匹配！预期: \(fileData.count), 实际: \(fileSize)")
                }
            } else {
                print("❌ LocalStorage: 文件验证失败 - 文件不存在")
                throw StorageError.fileSystemError(NSError(domain: "LocalStorage", code: -1, userInfo: [NSLocalizedDescriptionKey: "文件写入后验证失败"]))
            }
            
            // 报告进度
            progress(1.0)
        } catch {
            print("❌ LocalStorage: 文件操作失败: \(error)")
            print("   错误详情: \(error.localizedDescription)")
            if let nsError = error as NSError? {
                print("   Domain: \(nsError.domain)")
                print("   Code: \(nsError.code)")
                print("   UserInfo: \(nsError.userInfo)")
            }
            throw StorageError.fileSystemError(error)
        }
    }
    
    /// 创建目录
    public func createDirectory(path: String) async throws {
        let url = URL(fileURLWithPath: path)
        
        print("📁 LocalStorage: 创建目录: \(path)")
        
        // 处理安全范围访问
        var hasAccess = false
        if let securityURL = securityScopedURL, isAccessingSecurityScope {
            if url.path.hasPrefix(securityURL.path) {
                // 已经在安全范围内，可以直接访问
            } else {
                hasAccess = url.startAccessingSecurityScopedResource()
            }
        } else {
            hasAccess = url.startAccessingSecurityScopedResource()
        }
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        
        // 检查目录是否已存在
        if fileManager.fileExists(atPath: path) {
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                print("ℹ️ LocalStorage: 目录已存在，跳过创建")
                return
            } else {
                print("⚠️ LocalStorage: 路径已存在但不是目录")
                throw StorageError.invalidOperation
            }
        }
        
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
            print("✅ LocalStorage: 目录创建成功")
            
            // 验证目录是否真的创建成功
            if fileManager.fileExists(atPath: path) {
                print("✅ LocalStorage: 目录验证成功")
            } else {
                print("❌ LocalStorage: 目录验证失败 - 目录不存在")
                throw StorageError.invalidOperation
            }
        } catch {
            print("❌ LocalStorage: 目录创建失败: \(error)")
            print("   错误详情: \(error.localizedDescription)")
            if let nsError = error as NSError? {
                print("   Domain: \(nsError.domain)")
                print("   Code: \(nsError.code)")
                print("   UserInfo: \(nsError.userInfo)")
            }
            throw StorageError.fileSystemError(error)
        }
    }
    
    /// 删除文件或目录
    public func delete(path: String) async throws {
        let url = URL(fileURLWithPath: path)
        
        // 处理安全范围访问
        var hasAccess = false
        if let securityURL = securityScopedURL, isAccessingSecurityScope {
            if url.path.hasPrefix(securityURL.path) {
                // 已经在安全范围内，可以直接访问
            } else {
                hasAccess = url.startAccessingSecurityScopedResource()
            }
        } else {
            hasAccess = url.startAccessingSecurityScopedResource()
        }
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        
        guard fileManager.fileExists(atPath: path) else {
            return // 文件不存在，直接返回成功
        }
        
        try fileManager.removeItem(at: url)
    }
    
    /// 移动/重命名
    public func move(from sourcePath: String, to destinationPath: String) async throws {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let destinationURL = URL(fileURLWithPath: destinationPath)
        
        // 处理源文件安全范围访问
        var hasSourceAccess = false
        if let securityURL = securityScopedURL, isAccessingSecurityScope {
            if sourceURL.path.hasPrefix(securityURL.path) {
                // 已经在安全范围内，可以直接访问
            } else {
                hasSourceAccess = sourceURL.startAccessingSecurityScopedResource()
            }
        } else {
            hasSourceAccess = sourceURL.startAccessingSecurityScopedResource()
        }
        defer { if hasSourceAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        
        // 处理目标文件安全范围访问
        var hasDestinationAccess = false
        if let securityURL = securityScopedURL, isAccessingSecurityScope {
            if destinationURL.path.hasPrefix(securityURL.path) {
                // 已经在安全范围内，可以直接访问
            } else {
                hasDestinationAccess = destinationURL.startAccessingSecurityScopedResource()
            }
        } else {
            hasDestinationAccess = destinationURL.startAccessingSecurityScopedResource()
        }
        defer { if hasDestinationAccess { destinationURL.stopAccessingSecurityScopedResource() } }
        
        guard fileManager.fileExists(atPath: sourcePath) else {
            throw StorageError.notFound
        }
        
        // 确保目标目录存在
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        
        // 删除已存在的目标文件
        if fileManager.fileExists(atPath: destinationPath) {
            try fileManager.removeItem(at: destinationURL)
        }
        
        // 移动文件
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }
}

// MARK: - WebDAV Client Adapter

/// WebDAVClient适配器，使其符合StorageClient协议
public class WebDAVStorageAdapter: StorageClient {
    private let webDAVClient: WebDAVClient
    
    public init(webDAVClient: WebDAVClient = WebDAVClient.shared) {
        self.webDAVClient = webDAVClient
    }
    
    public func exists(path: String) async throws -> Bool {
        do {
            _ = try await webDAVClient.listDirectory(path: path)
            return true
        } catch {
            return false
        }
    }
    
    public func listDirectory(path: String) async throws -> [StorageResource] {
        let webDAVResources = try await webDAVClient.listDirectory(path: path)
        return webDAVResources.map { resource in
            StorageResource(
                path: resource.path,
                displayName: resource.displayName,
                isDirectory: resource.isDirectory,
                contentLength: resource.contentLength,
                contentType: resource.contentType,
                creationDate: resource.creationDate,
                lastModified: resource.lastModified,
                etag: resource.etag
            )
        }
    }
    
    public func downloadFile(path: String, to destinationURL: URL, progress: @escaping (Double) -> Void) async throws {
        try await webDAVClient.downloadFile(path: path, to: destinationURL, progress: progress)
    }
    
    public func uploadFile(localURL: URL, to remotePath: String, progress: @escaping (Double) -> Void) async throws {
        try await webDAVClient.uploadFile(localURL: localURL, to: remotePath, progress: progress)
    }
    
    public func createDirectory(path: String) async throws {
        try await webDAVClient.createDirectory(path: path)
    }
    
    public func delete(path: String) async throws {
        try await webDAVClient.delete(path: path)
    }
    
    public func move(from sourcePath: String, to destinationPath: String) async throws {
        try await webDAVClient.move(from: sourcePath, to: destinationPath)
    }
}

// MARK: - Errors

public enum StorageError: Error, LocalizedError {
    case notConfigured
    case notFound
    case invalidOperation
    case fileSystemError(Error)
    case permissionDenied
    
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "存储未配置"
        case .notFound:
            return "文件或目录不存在"
        case .invalidOperation:
            return "无效的操作"
        case .fileSystemError(let error):
            return "文件系统错误: \(error.localizedDescription)"
        case .permissionDenied:
            return "权限被拒绝"
        }
    }
}
