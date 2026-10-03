import Foundation
import CloudDriveContracts
import CloudDriveSupport

public struct Pan123FileDetailData: Codable, Sendable {
    public let fileID: Int64
    public let filename: String
    public let type: Int
    public let size: Int64
    public let etag: String?
    public let status: Int?
    public let parentFileID: Int64
    public let createAt: String?
    public let trashed: Int?
    
    public var isDirectory: Bool {
        return type == 1
    }
    
    public var isTrashed: Bool {
        return (trashed ?? 0) != 0
    }
}
