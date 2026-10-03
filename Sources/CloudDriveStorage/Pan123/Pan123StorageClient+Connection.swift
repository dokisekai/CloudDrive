import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit
import UniformTypeIdentifiers

extension Pan123StorageClient {
    public func testConnection() async throws -> Bool {
        do {
            _ = try await apiClient.getValidAccessToken()
            _ = try await listDirectory(path: "/")
            return true
        } catch {
            return false
        }
    }
    
    /// 获取今日使用与配额统计 (包含今日请求数、每分钟请求数、今日下载流量与剩余流量)
}
