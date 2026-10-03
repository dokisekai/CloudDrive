//
//  LocalWebDAVServer.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  轻量级纯本地 WebDAV 回环桥接服务
//  监听 127.0.0.1 本地回环端口，将 Mac 本地任意授权文件夹安全桥接为标准 WebDAV
//  彻底避开 macOS FileProvider Extension 跨进程沙箱权限隔离问题
//

import Foundation
import CloudDriveContracts
import CloudDriveSupport
import Network

/// 本地 WebDAV 回环服务
public class LocalWebDAVServer {
    public static let shared = LocalWebDAVServer()
    
    public private(set) var port: UInt16 = 28282
    public private(set) var isRunning: Bool = false
    
    private var listener: NWListener?
    let serverQueue = DispatchQueue(label: "net.aabg.CloudDrive.LocalWebDAVServer", qos: .userInitiated)
    let lock = NSLock()
    
    /// 注册的本地保险库字典：vaultId -> 本地文件夹 URL
    private(set) var registeredVaults: [String: URL] = [:]
    /// 安全作用域资源 URL 字典：vaultId -> 已激活访问的 SecurityScoped URL
    private var securityScopedURLs: [String: URL] = [:]
    
    private init() {}
    
    // MARK: - 注册与管理本地保险库
    
    /// 注册本地保险库（支持传入安全书签 bookmarkData）
    public func register(vaultId: String, localURL: URL, bookmarkData: Data? = nil) {
        lock.lock()
        defer { lock.unlock() }
        
        var effectiveURL = localURL
        if let bookmark = bookmarkData {
            var isStale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                if resolved.startAccessingSecurityScopedResource() {
                    logSuccess(.system, "🛡️ LocalWebDAV: Successfully restored security bookmark access: \(resolved.path)")
                    if let oldScoped = securityScopedURLs[vaultId] {
                        oldScoped.stopAccessingSecurityScopedResource()
                    }
                    securityScopedURLs[vaultId] = resolved
                    effectiveURL = resolved
                } else {
                    logWarning(.system, "⚠️ LocalWebDAV: Failed to start security-scoped resource access")
                }
            }
        } else {
            if effectiveURL.startAccessingSecurityScopedResource() {
                if let oldScoped = securityScopedURLs[vaultId] {
                    oldScoped.stopAccessingSecurityScopedResource()
                }
                securityScopedURLs[vaultId] = effectiveURL
            }
        }
        
        registeredVaults[vaultId] = effectiveURL
        logInfo(.system, "🌐 LocalWebDAV: Registered local vault [\(vaultId)] -> \(effectiveURL.path)")
    }
    
    /// 注销本地保险库
    public func unregister(vaultId: String) {
        lock.lock()
        defer { lock.unlock() }
        if let scoped = securityScopedURLs.removeValue(forKey: vaultId) {
            scoped.stopAccessingSecurityScopedResource()
        }
        registeredVaults.removeValue(forKey: vaultId)
        logInfo(.system, "🌐 LocalWebDAV: Unregistered local vault [\(vaultId)]")
    }
    
    /// 获取指定保险库的本地 WebDAV 基准 URL
    public func baseURL(for vaultId: String) -> URL {
        return URL(string: "http://127.0.0.1:\(port)/v/\(vaultId)/")!
    }
    
    // MARK: - 启动与停止
    
    /// 检测本地端口是否可用
    private func isPortAvailable(_ port: UInt16) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bindResult == 0
    }
    
    /// 启动本地服务（自动寻找可用端口）
    public func start(preferredPort: UInt16 = 28282) {
        lock.lock()
        defer { lock.unlock() }
        
        if isRunning {
            logInfo(.system, "🌐 LocalWebDAV: Server already running on port: \(port)")
            return
        }
        
        var currentPort = preferredPort
        var started = false
        
        while currentPort < preferredPort + 30 && !started {
            if !isPortAvailable(currentPort) {
                currentPort += 1
                continue
            }
            
            do {
                let params = NWParameters.tcp
                guard let nwPort = NWEndpoint.Port(rawValue: currentPort) else { break }
                let newListener = try NWListener(using: params, on: nwPort)
                
                newListener.newConnectionHandler = { [weak self] connection in
                    self?.handleConnection(connection)
                }
                
                newListener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        logSuccess(.system, "✅ LocalWebDAV: Loopback server ready on 127.0.0.1:\(currentPort)")
                    case .failed(let error):
                        logError(.system, "❌ LocalWebDAV: Listener failed: \(error)")
                    default:
                        break
                    }
                }
                
                newListener.start(queue: serverQueue)
                self.listener = newListener
                self.port = currentPort
                self.isRunning = true
                started = true
                logSuccess(.system, "🚀 LocalWebDAV: Started successfully on port \(currentPort)")
            } catch {
                logWarning(.system, "⚠️ LocalWebDAV: Port \(currentPort) busy or failed, trying next port: \(error)")
                currentPort += 1
            }
        }
    }
    
    /// 停止本地服务
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        
        listener?.cancel()
        listener = nil
        isRunning = false
        logInfo(.system, "🛑 LocalWebDAV: Server stopped")
    }
}
