import Foundation
import CloudDriveContracts
import CloudDriveSupport

public struct Pan123MkdirRequest: Codable, Sendable {
    public let name: String
    public let parentID: Int64
    
    public init(name: String, parentID: Int64) {
        self.name = name
        self.parentID = parentID
    }
}
