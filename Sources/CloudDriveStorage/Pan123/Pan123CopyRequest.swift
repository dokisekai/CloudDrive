import Foundation
import CloudDriveContracts
import CloudDriveSupport

public struct Pan123CopyRequest: Codable, Sendable {
    public let fileId: Int64
    public let targetDirId: Int64
    
    public init(fileId: Int64, targetDirId: Int64) {
        self.fileId = fileId
        self.targetDirId = targetDirId
    }
}
