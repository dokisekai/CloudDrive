import Foundation
import CloudDriveContracts
import CloudDriveSupport

public class WebDAVClient {
    public static let shared = WebDAVClient()
    
    let session: URLSession
    private let ownsSession: Bool
    let uploadCoordinator: WebDAVUploadCoordinator
    let uploadSession: URLSession
    private(set) var baseURL: URL?
    private(set) var credentials: URLCredential?
    
    public init(baseURL: URL? = nil, username: String? = nil, password: String? = nil, session: URLSession? = nil) {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 86400 // 24小时，支持任意大文件传输
        config.httpMaximumConnectionsPerHost = 16 // 提升并发上限避免请求排队
        self.session = session ?? URLSession(configuration: config, delegate: WebDAVTransferDelegate(), delegateQueue: nil)
        self.ownsSession = session == nil
        let coordinator = WebDAVUploadCoordinator()
        self.uploadCoordinator = coordinator
        self.uploadSession = URLSession(configuration: self.session.configuration, delegate: coordinator, delegateQueue: nil)
        if let baseURL = baseURL, let username = username, let password = password {
            self.baseURL = baseURL
            self.credentials = URLCredential(user: username, password: password, persistence: .forSession)
        }
    }
    
    deinit {
        uploadSession.invalidateAndCancel()
        if ownsSession { session.invalidateAndCancel() }
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
