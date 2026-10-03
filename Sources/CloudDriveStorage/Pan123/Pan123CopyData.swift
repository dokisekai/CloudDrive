import Foundation
import CloudDriveContracts
import CloudDriveSupport

public struct Pan123CopyData: Codable, Sendable {
    public let sourceFileId: Int64
    public let targetFileId: Int64
    
    public init(sourceFileId: Int64, targetFileId: Int64) {
        self.sourceFileId = sourceFileId
        self.targetFileId = targetFileId
    }
}
