//
//  NetworkMonitorService.swift
//  CloudDriveSync
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  系统网络连通性监听服务
//

import Foundation
import CloudDriveContracts
import CloudDriveSupport
import Network

/// 网络监听服务协议
public protocol NetworkMonitorServiceProtocol: AnyObject, Sendable {
    var currentStatus: NetworkStatus { get }
    var isOnline: Bool { get }
    func startMonitoring()
    func stopMonitoring()
    func onStatusChanged(_ handler: @escaping @Sendable (NetworkStatus) -> Void)
}

/// 基于 Apple NWPathMonitor 的系统网络监听服务
public final class NetworkMonitorService: NetworkMonitorServiceProtocol, @unchecked Sendable {
    public static let shared = NetworkMonitorService()
    
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.clouddrive.network.monitor")
    private let lock = NSLock()
    private var status: NetworkStatus = .unknown
    private var changeHandlers: [@Sendable (NetworkStatus) -> Void] = []
    private var isStarted = false
    
    public init() {
        startMonitoring()
    }
    
    deinit {
        stopMonitoring()
    }
    
    public var currentStatus: NetworkStatus {
        lock.lock()
        defer { lock.unlock() }
        return status
    }
    
    public var isOnline: Bool {
        return currentStatus == .online
    }
    
    public func startMonitoring() {
        lock.lock()
        defer { lock.unlock() }
        
        if isStarted { return }
        isStarted = true
        
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            
            let newStatus: NetworkStatus = path.status == .satisfied ? .online : .offline
            
            var handlersToNotify: [@Sendable (NetworkStatus) -> Void] = []
            self.lock.lock()
            let oldStatus = self.status
            if newStatus != oldStatus {
                self.status = newStatus
                handlersToNotify = self.changeHandlers
            }
            self.lock.unlock()
            
            if newStatus != oldStatus {
                Logger.shared.info(.sync, "Network status changed: \(newStatus == .online ? "online" : "offline")")
                for handler in handlersToNotify {
                    handler(newStatus)
                }
            }
        }
        
        monitor.start(queue: monitorQueue)
    }
    
    public func stopMonitoring() {
        lock.lock()
        defer { lock.unlock() }
        if isStarted {
            monitor.cancel()
            isStarted = false
        }
    }
    
    public func onStatusChanged(_ handler: @escaping @Sendable (NetworkStatus) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        changeHandlers.append(handler)
    }
}
