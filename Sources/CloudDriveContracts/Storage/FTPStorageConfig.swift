import Foundation

public struct FTPStorageConfig: Codable, Hashable, Sendable {
    public var host: String             // 主机名或 IP
    public var port: Int                // 端口 (默认 21)
    public var username: String         // 用户名
    public var password: String         // 密码
    public var path: String             // 初始目录路径 (例如 / 或 /home/ftp)
    public var useTLS: Bool             // 是否使用 FTPS (FTP over TLS/SSL)
    
    public init(
        host: String,
        port: Int = 21,
        username: String = "",
        password: String = "",
        path: String = "/",
        useTLS: Bool = false
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.path = path.isEmpty ? "/" : path
        self.useTLS = useTLS
    }
    
    public var scheme: String {
        return useTLS ? "ftps" : "ftp"
    }
    
    public var displayURL: String {
        return "\(scheme)://\(username.isEmpty ? "" : "\(username)@")\(host):\(port)\(path)"
    }
}
