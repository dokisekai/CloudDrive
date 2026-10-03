import Foundation
import CloudDriveContracts
import CloudDriveSupport

public struct Pan123MkdirData: Codable, Sendable {
    public let dirID: Int64
    
    public init(dirID: Int64) {
        self.dirID = dirID
    }
}

// MARK: - Download
