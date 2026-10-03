import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit

extension Pan123APIClient {
    // MARK: - Core Request Dispatcher with 429 & 401 Retry
    
    /// 底层请求执行器：内置 Token 自动续期与 429 智能指数退避重试 (Exponential Backoff with Jitter)
    func executeWithRetry(
        makeRequest: (String) throws -> URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        var rateLimitAttempts = 0
        var hasRefreshedToken = false
        
        while true {
            // 本地 SQLite 频率限制与每日配额节流门控 (支持主动平滑等待)
            let maxPerMinute = config.maxRequestsPerMinute ?? 600
            let maxPerDay = config.maxRequestsPerDay ?? 100_000
            try await databaseStore.acquireRequestSlot(
                clientID: config.clientID,
                maxPerMinute: maxPerMinute,
                maxPerDay: maxPerDay
            )
            
            let token = try await getValidAccessToken()
            let request = try makeRequest(token)
            
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw StorageError.networkError("网络请求失败: \(error.localizedDescription)")
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw StorageError.networkError("Invalid HTTP response")
            }
            
            // 1. HTTP 401 凭据失效处理
            if httpResponse.statusCode == 401 {
                if !hasRefreshedToken && !config.clientID.isEmpty {
                    hasRefreshedToken = true
                    _ = try await getValidAccessToken(forceRefresh: true)
                    continue
                } else {
                    throw StorageError.authenticationFailed
                }
            }
            
            // 2. HTTP 429 频率超限处理
            if httpResponse.statusCode == 429 {
                if rateLimitAttempts < maxRateLimitRetries {
                    rateLimitAttempts += 1
                    let delay = baseRetryDelay * pow(2.0, Double(rateLimitAttempts - 1)) + Double.random(in: 0...0.05)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                } else {
                    throw StorageError.networkError("123云盘请求过于频繁，已被限流 (HTTP 429)")
                }
            }
            
            // 3. 检查响应体中的业务 code (123云盘部分接口在限流或鉴权失败时 HTTP 状态码仍为 200)
            if let jsonObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = jsonObj["code"] as? Int {
                if code == 401 {
                    if !hasRefreshedToken && !config.clientID.isEmpty {
                        hasRefreshedToken = true
                        _ = try await getValidAccessToken(forceRefresh: true)
                        continue
                    } else {
                        throw StorageError.authenticationFailed
                    }
                }
                
                if code == 429 {
                    let msg = (jsonObj["message"] as? String) ?? "请求太频繁"
                    if rateLimitAttempts < maxRateLimitRetries {
                        rateLimitAttempts += 1
                        let delay = baseRetryDelay * pow(2.0, Double(rateLimitAttempts - 1)) + Double.random(in: 0...0.05)
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    } else {
                        throw StorageError.networkError("123云盘请求过于频繁，已被限流 (429): \(msg)")
                    }
                }
            }
            
            return (data, httpResponse)
        }
    }
    
    /// 执行统一 JSON 请求并解析返回泛型 Data
    public func sendRequest<Request: Encodable, ResponseData: Decodable>(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: Request? = nil,
        customBaseURL: URL? = nil
    ) async throws -> ResponseData {
        let (data, _) = try await executeWithRetry { token in
            var components = URLComponents(url: (customBaseURL ?? self.baseURL).appendingPathComponent(path), resolvingAgainstBaseURL: true)!
            if !queryItems.isEmpty {
                components.queryItems = queryItems
            }
            guard let url = components.url else {
                throw StorageError.invalidOperation
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("open_platform", forHTTPHeaderField: "Platform")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            if let body = body {
                request.httpBody = try JSONEncoder().encode(body)
            }
            return request
        }
        
        let apiResponse = try JSONDecoder().decode(Pan123Response<ResponseData>.self, from: data)
        guard apiResponse.code == 0 else {
            throw mapPan123Error(code: apiResponse.code, message: apiResponse.message)
        }
        
        guard let dataPayload = apiResponse.data else {
            throw StorageError.serverError(statusCode: apiResponse.code, message: "Response missing data payload")
        }
        
        return dataPayload
    }
    
    /// 执行无 Body 的请求
    public func sendRequest<ResponseData: Decodable>(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        customBaseURL: URL? = nil
    ) async throws -> ResponseData {
        let noBody: String? = nil
        return try await sendRequest(
            path: path,
            method: method,
            queryItems: queryItems,
            body: noBody,
            customBaseURL: customBaseURL
        )
    }
    
    /// 执行无需泛型 Data 返回（如删除、重命名返回 data: null）的请求
    public func sendEmptyResponseRequest<Request: Encodable>(
        path: String,
        method: String = "POST",
        queryItems: [URLQueryItem] = [],
        body: Request? = nil
    ) async throws {
        let (data, _) = try await executeWithRetry { token in
            var components = URLComponents(url: self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: true)!
            if !queryItems.isEmpty {
                components.queryItems = queryItems
            }
            guard let url = components.url else {
                throw StorageError.invalidOperation
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("open_platform", forHTTPHeaderField: "Platform")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            if let body = body {
                request.httpBody = try JSONEncoder().encode(body)
            }
            return request
        }
        
        let apiResponse = try JSONDecoder().decode(Pan123Response<Pan123EmptyData>.self, from: data)
        if apiResponse.code != 0 {
            throw mapPan123Error(code: apiResponse.code, message: apiResponse.message)
        }
    }
}
