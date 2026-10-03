import Foundation
import CloudDriveContracts
import CloudDriveSupport

public struct Pan123CreateFileRequest: Codable, Sendable {
    public let parentFileID: Int64
    public let filename: String
    public let etag: String       // 文件完整 MD5
    public let size: Int64        // 文件字节大小
    public let duplicate: Int     // 1: 保留两者, 2: 覆盖原文件
    public let containDir: Bool?
    
    public init(
        parentFileID: Int64,
        filename: String,
        etag: String,
        size: Int64,
        duplicate: Int = 2,
        containDir: Bool? = false
    ) {
        self.parentFileID = parentFileID
        self.filename = filename
        self.etag = etag
        self.size = size
        self.duplicate = duplicate
        self.containDir = containDir
    }
}
