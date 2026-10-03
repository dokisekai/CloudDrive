import Foundation
import CloudDriveContracts
import CloudDriveSupport

public struct Pan123TokenRequest: Codable, Sendable {
    public let clientID: String
    public let clientSecret: String
    
    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}
