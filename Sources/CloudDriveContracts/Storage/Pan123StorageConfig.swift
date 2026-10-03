import Foundation

public struct Pan123StorageConfig: Codable, Hashable, Sendable {
    public var clientID: String          // 开放平台分配的 clientID
    public var clientSecret: String      // 开放平台分配的 clientSecret
    public var accessToken: String?      // 直接提供的 access_token (可选)
    public var rootFolderID: Int64       // 根目录挂载的文件夹ID (0 为网盘根目录)
    public var rootPath: String          // 逻辑显示根路径 (可选，默认 "/")
    public var maxRequestsPerMinute: Int? // 每分钟最大请求限制 (默认 600，即约 10/s)
    public var maxRequestsPerDay: Int?    // 每天最大请求限制 (默认 100,000，0 为不限)
    public var maxDailyDownloadBytes: Int64? // 每天下载流量上限 (默认 1GB = 1,073,741,824，0 为不限)
    
    public init(
        clientID: String = "",
        clientSecret: String = "",
        accessToken: String? = nil,
        rootFolderID: Int64 = 0,
        rootPath: String = "/",
        maxRequestsPerMinute: Int? = 600,
        maxRequestsPerDay: Int? = 100_000,
        maxDailyDownloadBytes: Int64? = 1024 * 1024 * 1024
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.accessToken = accessToken
        self.rootFolderID = rootFolderID
        self.rootPath = rootPath.isEmpty ? "/" : rootPath
        self.maxRequestsPerMinute = maxRequestsPerMinute
        self.maxRequestsPerDay = maxRequestsPerDay
        self.maxDailyDownloadBytes = maxDailyDownloadBytes
    }
}

// MARK: - Unified Storage Configuration Enum
