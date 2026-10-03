import Foundation
import CloudDriveContracts
import CloudDriveSupport

public struct Pan123FileItem: Codable, Sendable {
    public let fileId: Int64
    public let filename: String
    public let parentFileId: Int64
    public let type: Int          // 0: 文件, 1: 文件夹
    public let etag: String?      // md5
    public let size: Int64
    public let category: Int?
    public let status: Int?
    public let trashed: Int?      // 0: 否, 1: 是
    public let createAt: String?
    public let updateAt: String?
    
    public var isDirectory: Bool {
        return type == 1
    }
    
    public var isTrashed: Bool {
        return (trashed ?? 0) != 0
    }
    
    public init(
        fileId: Int64,
        filename: String,
        parentFileId: Int64,
        type: Int,
        etag: String? = nil,
        size: Int64 = 0,
        category: Int? = nil,
        status: Int? = nil,
        trashed: Int? = 0,
        createAt: String? = nil,
        updateAt: String? = nil
    ) {
        self.fileId = fileId
        self.filename = filename
        self.parentFileId = parentFileId
        self.type = type
        self.etag = etag
        self.size = size
        self.category = category
        self.status = status
        self.trashed = trashed
        self.createAt = createAt
        self.updateAt = updateAt
    }
}
