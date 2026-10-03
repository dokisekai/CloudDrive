//
//  Pan123APIClient.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  123云盘开放平台底层 HTTP 客户端封装
//

import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit

/// 123云盘开放平台 API 客户端
public actor Pan123APIClient {
    public let baseURL: URL
    public let config: Pan123StorageConfig
    let session: URLSession
    
    // 数据库持久化存储与频控支持
    public let databaseStore: Pan123DatabaseStore
    
    // 运行时 Token 状态
    private var cachedAccessToken: String?
    private var tokenExpiresAt: Date?
    private var inFlightTokenTask: Task<String, Error>?
    
    // 频率与重试控制 (QPS 与 429 限流保护)
    public var baseRetryDelay: TimeInterval
    public var maxRateLimitRetries: Int
    
    private let isoDateFormatter: ISO8601DateFormatter = {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime]
        return df
    }()
    
    public init(
        config: Pan123StorageConfig,
        baseURL: URL = URL(string: "https://open-api.123pan.com")!,
        session: URLSession = .shared,
        databaseStore: Pan123DatabaseStore? = nil,
        baseRetryDelay: TimeInterval = 0.5,
        maxRateLimitRetries: Int = 3
    ) {
        self.config = config
        self.baseURL = baseURL
        self.session = session
        self.databaseStore = databaseStore ?? Pan123DatabaseStore.shared
        self.baseRetryDelay = baseRetryDelay
        self.maxRateLimitRetries = maxRateLimitRetries
        if let directToken = config.accessToken, !directToken.isEmpty {
            self.cachedAccessToken = directToken
        }
    }
    
    /// 动态设置频率限制重试策略
    public func setRetryPolicy(baseDelay: TimeInterval, maxRetries: Int) {
        self.baseRetryDelay = baseDelay
        self.maxRateLimitRetries = maxRetries
    }
    
    // MARK: - Token Management (并发防抖与 30 天强缓存 + SQLite 跨进程持久化)
    
    /// 获取当前可用的 AccessToken（有效缓存期内优先复用内存与数据库持久化 Token，防并发防互踢）
    public func getValidAccessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh {
            // 1. 优先检查内存缓存
            if let token = cachedAccessToken {
                if let expiresAt = tokenExpiresAt {
                    if Date().addingTimeInterval(1800) < expiresAt {
                        return token
                    }
                } else {
                    return token
                }
            }
            
            // 2. 检查本地 SQLite 数据库持久化缓存 (跨 App 重启/跨进程复用，防超过 3 个 Token 互踢)
            if !config.clientID.isEmpty, let (dbToken, dbExpiresAt) = try? databaseStore.loadToken(clientID: config.clientID) {
                if Date().addingTimeInterval(1800) < dbExpiresAt {
                    self.cachedAccessToken = dbToken
                    self.tokenExpiresAt = dbExpiresAt
                    return dbToken
                }
            }
        }
        
        // 尝试通过 clientID 和 clientSecret 换取
        guard !config.clientID.isEmpty && !config.clientSecret.isEmpty else {
            if let token = cachedAccessToken, !token.isEmpty {
                return token
            }
            throw StorageError.notConfigured
        }
        
        if forceRefresh {
            self.cachedAccessToken = nil
            self.tokenExpiresAt = nil
            try? databaseStore.deleteToken(clientID: config.clientID)
        }
        
        // 并发防抖：如果已有正在换取 Token 的任务，共用该任务，避免 client_id 超过 3 个活跃 token 限制
        if let existingTask = inFlightTokenTask {
            return try await existingTask.value
        }
        
        let task = Task<String, Error> {
            let (newToken, expiresAt) = try await self.performFetchAccessToken()
            self.saveToken(token: newToken, expiresAt: expiresAt)
            try? self.databaseStore.saveToken(clientID: self.config.clientID, token: newToken, expiredAt: expiresAt)
            return newToken
        }
        self.inFlightTokenTask = task
        
        do {
            let token = try await task.value
            self.inFlightTokenTask = nil
            return token
        } catch {
            self.inFlightTokenTask = nil
            throw error
        }
    }
    
    private func saveToken(token: String, expiresAt: Date) {
        self.cachedAccessToken = token
        self.tokenExpiresAt = expiresAt
    }
    
    /// 调用 /api/v1/access_token 换取 Token
    private func performFetchAccessToken() async throws -> (token: String, expiresAt: Date) {
        let endpoint = baseURL.appendingPathComponent("api/v1/access_token")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("open_platform", forHTTPHeaderField: "Platform")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = Pan123TokenRequest(clientID: config.clientID, clientSecret: config.clientSecret)
        request.httpBody = try JSONEncoder().encode(body)
        
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw StorageError.networkError("Invalid HTTP response during token acquisition")
        }
        
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw StorageError.authenticationFailed
        }
        
        let apiResponse = try JSONDecoder().decode(Pan123Response<Pan123TokenData>.self, from: data)
        guard apiResponse.code == 0, let tokenData = apiResponse.data else {
            if apiResponse.code == 401 {
                throw StorageError.authenticationFailed
            }
            if apiResponse.code == 429 {
                throw StorageError.networkError("获取 123云盘 Token 请求太频繁(429)，已被限流")
            }
            throw mapPan123Error(code: apiResponse.code, message: apiResponse.message)
        }
        
        let expiresAt: Date
        if let date = isoDateFormatter.date(from: tokenData.expiredAt) {
            expiresAt = date
        } else {
            // 默认按 30 天有效期算
            expiresAt = Date().addingTimeInterval(30 * 86400)
        }
        
        return (tokenData.accessToken, expiresAt)
    }
}
