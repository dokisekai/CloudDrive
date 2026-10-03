import Foundation
import CloudDriveContracts
import CloudDriveSupport

public class WebDAVClient {
    public static let shared = WebDAVClient()
    
    let session: URLSession
    private(set) var baseURL: URL?
    private(set) var credentials: URLCredential?
    
    public init(baseURL: URL? = nil, username: String? = nil, password: String? = nil, session: URLSession? = nil) {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 86400 // 24小时，支持任意大文件传输
        self.session = session ?? URLSession(configuration: config)
        if let baseURL = baseURL, let username = username, let password = password {
            self.baseURL = baseURL
            self.credentials = URLCredential(user: username, password: password, persistence: .forSession)
        }
    }
    
    // MARK: - Configuration
    
    /// 配置 WebDAV 服务器
    public func configure(baseURL: URL, username: String, password: String) {
        self.baseURL = baseURL
        self.credentials = URLCredential(user: username, password: password, persistence: .forSession)
    }
    
    public func buildURL(for path: String) throws -> URL {
        try WebDAVPathResolver.buildURL(for: path, baseURL: baseURL)
    }
}
