import Foundation
import CloudDriveContracts
import CloudDriveSupport

public struct Pan123MoveRequest: Codable, Sendable {
    public let fileIDs: [Int64]
    public let toParentFileID: Int64
    
    public init(fileIDs: [Int64], toParentFileID: Int64) {
        self.fileIDs = fileIDs
        self.toParentFileID = toParentFileID
    }
}
