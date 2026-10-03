import Foundation

public enum StorageType: String, Codable, CaseIterable, Identifiable, Sendable {
    case webdav = "webdav"
    case s3 = "s3"
    case smb = "smb"
    case ftp = "ftp"
    case pan123 = "pan123"
    case local = "local"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .webdav: return "WebDAV"
        case .s3: return "Amazon S3 / 对象存储"
        case .smb: return "SMB / Windows 共享"
        case .ftp: return "FTP / FTPS"
        case .pan123: return "123云盘"
        case .local: return "本地文件夹"
        }
    }
    
    public var iconName: String {
        switch self {
        case .webdav: return "network"
        case .s3: return "externaldrive.connected.to.line.below"
        case .smb: return "server.rack"
        case .ftp: return "arrow.up.arrow.down.square"
        case .pan123: return "cloud.fill"
        case .local: return "folder.fill"
        }
    }
    
    public var defaultPort: Int {
        switch self {
        case .webdav: return 443
        case .s3: return 443
        case .smb: return 445
        case .ftp: return 21
        case .pan123: return 443
        case .local: return 0
        }
    }
}

// MARK: - Protocol Configurations
