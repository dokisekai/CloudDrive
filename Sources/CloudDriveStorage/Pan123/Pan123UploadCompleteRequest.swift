import Foundation
import CloudDriveContracts
import CloudDriveSupport

public struct Pan123UploadCompleteRequest: Codable, Sendable {
    public let preuploadID: String
    
    public init(preuploadID: String) {
        self.preuploadID = preuploadID
    }
}
