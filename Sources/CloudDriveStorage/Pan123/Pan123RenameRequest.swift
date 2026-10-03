import Foundation
import CloudDriveContracts
import CloudDriveSupport

public struct Pan123RenameRequest: Codable, Sendable {
    public let fileId: Int64
    public let fileName: String
    
    public init(fileId: Int64, fileName: String) {
        self.fileId = fileId
        self.fileName = fileName
    }
}
