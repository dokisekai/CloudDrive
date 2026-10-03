//
//  NetworkReachabilityStatus.swift
//  CloudDriveSync
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  网络连通状态与接口类型枚举
//

import Foundation
import CloudDriveContracts

public enum NetworkInterfaceType: String, Codable, Sendable {
    case wifi
    case cellular
    case wiredEthernet
    case loopback
    case unknown
}

public enum DisconnectReason: String, Codable, Sendable {
    case noConnection
    case dnsFailure
    case timeout
    case captivePortalRequired // 需要网页认证的公共 Wifi
}

public enum NetworkReachabilityStatus: Sendable, Equatable {
    case online(interface: NetworkInterfaceType, isExpensive: Bool, isConstrained: Bool)
    case offline(reason: DisconnectReason)
}
