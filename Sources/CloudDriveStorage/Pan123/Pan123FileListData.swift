import Foundation
import CloudDriveContracts
import CloudDriveSupport

public struct Pan123FileListData: Codable, Sendable {
    public let lastFileId: Int64
    public let fileList: [Pan123FileItem]?
    
    public init(lastFileId: Int64, fileList: [Pan123FileItem]?) {
        self.lastFileId = lastFileId
        self.fileList = fileList
    }
}

// MARK: - Directory Creation
