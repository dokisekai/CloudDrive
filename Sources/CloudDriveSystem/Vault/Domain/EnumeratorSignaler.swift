import CloudDriveContracts
import CloudDriveSupport
import CloudDriveSecurity
//
//  EnumeratorSignaler.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  FileProvider 信号防抖执行器 (120ms 防抖，避免并发洪峰冲击系统 enumerator)
//

import Foundation
import FileProvider

public actor EnumeratorSignaler {
    public static let shared = EnumeratorSignaler()
    
    private var pendingTasks: [String: Task<Void, Never>] = [:]
    private var pendingContainers: [String: Set<NSFileProviderItemIdentifier>] = [:]
    private let debounceIntervalNanoseconds: UInt64 = 120_000_000 // 120ms
    
    private init() {}
    
    /// 向指定 domain 发送防抖后的 enumerator 刷新信号（累加待刷新容器，防抖窗口内不丢弃任一容器）
    public func signal(
        for domain: NSFileProviderDomain,
        containerItemIdentifiers: [NSFileProviderItemIdentifier] = [.workingSet, .rootContainer]
    ) {
        let key = domain.identifier.rawValue
        var containers = pendingContainers[key] ?? Set()
        for id in containerItemIdentifiers {
            containers.insert(id)
        }
        pendingContainers[key] = containers
        
        pendingTasks[key]?.cancel()
        
        pendingTasks[key] = Task { [debounceIntervalNanoseconds] in
            do {
                try await Task.sleep(nanoseconds: debounceIntervalNanoseconds)
            } catch {
                return // 被新任务取消，但 pendingContainers 已合并累计，新任务会一并刷新
            }
            
            guard !Task.isCancelled else { return }
            guard let toSignal = self.drainContainers(for: key) else { return }
            guard let manager = NSFileProviderManager(for: domain) else { return }
            
            for container in toSignal {
                do {
                    try await manager.signalEnumerator(for: container)
                } catch {
                    // 忽略无活跃观察者时的正常错误
                }
            }
        }
    }
    
    private func drainContainers(for key: String) -> Set<NSFileProviderItemIdentifier>? {
        pendingTasks.removeValue(forKey: key)
        return pendingContainers.removeValue(forKey: key)
    }
    
    /// 向指定 domain 和 itemIdentifier 发送防抖刷新信号
    public func signal(domain: NSFileProviderDomain, for identifier: NSFileProviderItemIdentifier) {
        signal(for: domain, containerItemIdentifiers: [identifier])
    }
    
    /// 立即刷新（绕过防抖，用于首次挂载或手动同步触发）
    public func signalImmediately(
        for domain: NSFileProviderDomain,
        containerItemIdentifiers: [NSFileProviderItemIdentifier] = [.workingSet, .rootContainer]
    ) async {
        let key = domain.identifier.rawValue
        pendingTasks[key]?.cancel()
        pendingTasks.removeValue(forKey: key)
        
        var toSignal = pendingContainers.removeValue(forKey: key) ?? Set()
        for id in containerItemIdentifiers {
            toSignal.insert(id)
        }
        
        guard let manager = NSFileProviderManager(for: domain) else { return }
        for container in toSignal {
            do {
                try await manager.signalEnumerator(for: container)
            } catch {
                // 忽略无活跃观察者时的正常错误
            }
        }
    }
}
