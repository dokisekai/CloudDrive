import Foundation
import CloudDriveContracts
import CloudDriveSupport
import Network
import UniformTypeIdentifiers

extension FTPStorageClient {
    // MARK: - Path Resolution
    
    /// 将 VFS 逻辑路径转换为 FTP 绝对路径
    func resolveFTPPath(_ path: String) -> String {
        let clean = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let baseClean = config.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if baseClean.isEmpty {
            return clean.isEmpty ? "/" : "/\(clean)"
        } else {
            return clean.isEmpty ? "/\(baseClean)" : "/\(baseClean)/\(clean)"
        }
    }
    
    /// 构造标准 FTP URL (用于 URLSession 访问)
    func buildFTPURL(for path: String) -> URL? {
        let resolved = resolveFTPPath(path)
        var comp = URLComponents()
        comp.scheme = config.scheme
        comp.host = config.host
        comp.port = config.port
        if !config.username.isEmpty {
            comp.user = config.username
            if !config.password.isEmpty {
                comp.password = config.password
            }
        }
        comp.percentEncodedPath = resolved.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? resolved
        return comp.url
    }
}
