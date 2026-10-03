import Foundation

public enum StorageError: Error, LocalizedError, Sendable {
    case notConfigured
    case notFound
    case invalidOperation
    case fileSystemError(String)
    case permissionDenied
    case authenticationFailed
    case networkError(String)
    case serverError(statusCode: Int, message: String)
    case notSupported(String)
    
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "存储未配置"
        case .notFound:
            return "文件或目录不存在"
        case .invalidOperation:
            return "无效的操作"
        case .fileSystemError(let msg):
            return "文件系统错误: \(msg)"
        case .permissionDenied:
            return "权限被拒绝"
        case .authenticationFailed:
            return "身份认证失败，请检查账号密码或密钥"
        case .networkError(let msg):
            return "网络连接错误: \(msg)"
        case .serverError(let code, let msg):
            return "服务器返回错误 (状态码 \(code)): \(msg)"
        case .notSupported(let msg):
            return "当前存储类型不支持该功能: \(msg)"
        }
    }
    
    public static func fileSystemError(_ error: Error) -> StorageError {
        return .fileSystemError(error.localizedDescription)
    }
}

public extension StorageError {
    var isPreconditionFailure: Bool {
        if case .serverError(let status, _) = self { return status == 412 }
        return false
    }

    var statusCode: Int? {
        switch self {
        case .serverError(let status, _):
            return status
        case .notFound:
            return 404
        case .permissionDenied:
            return 403
        case .authenticationFailed:
            return 401
        default:
            return nil
        }
    }
}
