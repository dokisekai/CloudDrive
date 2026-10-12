import Foundation

public enum WebDAVError: Error, CustomNSError {
    case notConfigured
    case invalidResponse
    case serverError(Int)
    case parseError
    case authenticationFailed
    case fileNotFound
    case notConnectedToInternet
    case timeout
    case invalidPath
    
    public static var errorDomain: String {
        return "com.clouddrive.webdav"
    }
    
    public var errorCode: Int {
        switch self {
        case .notConfigured:
            return 1001
        case .invalidResponse:
            return 1002
        case .serverError(let statusCode):
            return statusCode  // 使用实际的HTTP状态码
        case .parseError:
            return 1003
        case .authenticationFailed:
            return 1004
        case .fileNotFound:
            return 1005
        case .notConnectedToInternet:
            return 1006
        case .timeout:
            return 1007
        case .invalidPath:
            return 1008
        }
    }
    
    public var errorUserInfo: [String : Any] {
        switch self {
        case .notConfigured:
            return [NSLocalizedDescriptionKey: "WebDAV client is not configured"]
        case .invalidResponse:
            return [NSLocalizedDescriptionKey: "Invalid WebDAV response"]
        case .serverError(let statusCode):
            return [NSLocalizedDescriptionKey: "Server error (\(statusCode))"]
        case .parseError:
            return [NSLocalizedDescriptionKey: "Failed to parse WebDAV response"]
        case .authenticationFailed:
            return [NSLocalizedDescriptionKey: "WebDAV authentication failed"]
        case .fileNotFound:
            return [NSLocalizedDescriptionKey: "File not found"]
        case .notConnectedToInternet:
            return [NSLocalizedDescriptionKey: "Not connected to internet"]
        case .timeout:
            return [NSLocalizedDescriptionKey: "Request timed out"]
        case .invalidPath:
            return [NSLocalizedDescriptionKey: "Invalid WebDAV path"]
        }
    }
}
