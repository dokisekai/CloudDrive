import Foundation
import CloudDriveContracts
import CloudDriveSupport

public struct Pan123TrashRequest: Codable, Sendable {
    public let fileIDs: [Int64]
    
    public init(fileIDs: [Int64]) {
        self.fileIDs = fileIDs
    }
}
