import Foundation

public enum StorageConfiguration: Codable, Hashable, Sendable {
    case webdav(WebDAVStorageConfig)
    case s3(S3StorageConfig)
    case smb(SMBStorageConfig)
    case ftp(FTPStorageConfig)
    case pan123(Pan123StorageConfig)
    case local(LocalStorageConfig)
    
    public var type: StorageType {
        switch self {
        case .webdav: return .webdav
        case .s3: return .s3
        case .smb: return .smb
        case .ftp: return .ftp
        case .pan123: return .pan123
        case .local: return .local
        }
    }
    
    public var summaryDescription: String {
        switch self {
        case .webdav(let cfg):
            return "WebDAV (\(cfg.baseURL))"
        case .s3(let cfg):
            return "S3 [\(cfg.bucket)] (\(cfg.endpoint))"
        case .smb(let cfg):
            return "SMB [\(cfg.share)] (\(cfg.host))"
        case .ftp(let cfg):
            return "\(cfg.useTLS ? "FTPS" : "FTP") (\(cfg.host):\(cfg.port))"
        case .pan123(let cfg):
            let rootDesc = cfg.rootFolderID == 0 ? "根目录" : "ID:\(cfg.rootFolderID)"
            return "123云盘 (\(rootDesc))"
        case .local(let cfg):
            return "本地 (\(cfg.path))"
        }
    }
    
    public var url: URL? {
        switch self {
        case .webdav(let cfg): return URL(string: cfg.baseURL)
        case .s3(let cfg): return URL(string: cfg.endpoint)
        case .smb(let cfg): return cfg.fullSMBURL
        case .ftp(let cfg): return URL(string: "\(cfg.scheme)://\(cfg.host):\(cfg.port)")
        case .pan123: return URL(string: "https://open-api.123pan.com")
        case .local(let cfg): return URL(fileURLWithPath: cfg.path)
        }
    }
    
    public var username: String? {
        switch self {
        case .webdav(let cfg): return cfg.username
        case .s3(let cfg): return cfg.accessKey
        case .smb(let cfg): return cfg.username
        case .ftp(let cfg): return cfg.username
        case .pan123(let cfg): return cfg.clientID.isEmpty ? nil : cfg.clientID
        case .local: return nil
        }
    }
}

extension StorageConfiguration {
    public var secret: String? {
        switch self {
        case .webdav(let c): return c.password
        case .s3(let c): return c.secretKey
        case .smb(let c): return c.password
        case .ftp(let c): return c.password
        case .pan123(let c):
            if !c.clientSecret.isEmpty { return c.clientSecret }
            if let token = c.accessToken, !token.isEmpty { return token }
            return ""
        case .local: return nil
        }
    }

    public func replacingSecret(_ secret: String) -> StorageConfiguration {
        switch self {
        case .webdav(var c): c.password = secret; return .webdav(c)
        case .s3(var c): c.secretKey = secret; return .s3(c)
        case .smb(var c): c.password = secret; return .smb(c)
        case .ftp(var c): c.password = secret; return .ftp(c)
        case .pan123(var c):
            if secret.isEmpty {
                c.clientSecret = ""
                c.accessToken = nil
            } else if !c.clientSecret.isEmpty || c.accessToken == nil {
                c.clientSecret = secret
            } else {
                c.accessToken = secret
            }
            return .pan123(c)
        case .local: return self
        }
    }

    public var withoutSecrets: StorageConfiguration { replacingSecret("") }
}
