import Foundation

public struct SMBStorageConfig: Codable, Hashable, Sendable {
    public var host: String             // 主机名或 IP (例如 192.168.1.100 或 nas.local)
    public var share: String            // 共享名 (例如 Data 或 Media)
    public var path: String             // 相对共享根目录的路径 (例如 /documents)
    public var username: String         // 用户名
    public var password: String         // 密码
    public var domain: String?          // 域名或工作组 (可选，例如 WORKGROUP)
    public var port: Int                // 端口 (默认 445)
    
    public init(
        host: String,
        share: String,
        path: String = "/",
        username: String = "",
        password: String = "",
        domain: String? = nil,
        port: Int = 445
    ) {
        self.host = host
        self.share = share
        self.path = path.isEmpty ? "/" : path
        self.username = username
        self.password = password
        self.domain = domain
        self.port = port
    }
    
    /// 构造标准 SMB URL (不包含密码以供显示)
    public var displayURL: String {
        return "smb://\(username.isEmpty ? "" : "\(username)@")\(host):\(port)/\(share)"
    }
    
    /// 构造完整包含认证的 SMB URL
    public var fullSMBURL: URL? {
        let authPart: String
        if !username.isEmpty {
            let encodedUser = username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? username
            if !password.isEmpty {
                let encodedPass = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password
                authPart = "\(encodedUser):\(encodedPass)@"
            } else {
                authPart = "\(encodedUser)@"
            }
        } else {
            authPart = ""
        }
        let cleanShare = share.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let portPart = port == 445 ? "" : ":\(port)"
        return URL(string: "smb://\(authPart)\(host)\(portPart)/\(cleanShare)")
    }
}
