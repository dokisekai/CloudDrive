import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit

extension Pan123APIClient {
    // MARK: - Error Mapping
    
    /// 将 123云盘 开放平台业务错误码精确映射为用户友好的 StorageError
    public func mapPan123Error(code: Int, message: String) -> StorageError {
        switch code {
        case 401:
            return .authenticationFailed
        case 403:
            return .permissionDenied
        case 404, 5066:
            return .notFound
        case 429:
            return .networkError("123云盘请求过于频繁，已被限流 (429): \(message)")
        case 200020:
            return .serverError(
                statusCode: 200020,
                message: "123云盘 OpenAPI 仅限开通开发者权益包用户使用，请前往 123云盘商品中心购买开发者权益包: \(message)"
            )
        case 5113:
            return .serverError(
                statusCode: 5113,
                message: "您今日自用下载流量已超出 1GB 上限(5113)，请升级 VIP 会员或明日重试: \(message)"
            )
        case 5067:
            return .serverError(statusCode: 412, message: "文件或目录已存在(5067): \(message)")
        case 5068:
            return .serverError(statusCode: 507, message: "123云盘空间配额不足(5068): \(message)")
        case 5070:
            return .serverError(statusCode: 410, message: "文件在回收站中不存在或已被清理(5070): \(message)")
        case 5075:
            return .notSupported("文件名不合法或包含非法字符(5075): \(message)")
        default:
            return .serverError(statusCode: code, message: message)
        }
    }
}
