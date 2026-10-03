import Foundation

public enum NetworkStatus: String, Codable {
    case unknown = "unknown"
    case offline = "offline"
    case online = "online"
    case limited = "limited"  // 受限连接（如移动数据）
}

// MARK: - 同步操作

/// 同步操作类型
