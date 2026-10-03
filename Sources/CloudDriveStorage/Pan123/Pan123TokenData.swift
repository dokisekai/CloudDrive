import Foundation
import CloudDriveContracts
import CloudDriveSupport

public struct Pan123TokenData: Codable, Sendable {
    public let accessToken: String
    public let expiredAt: String
    
    public init(accessToken: String, expiredAt: String) {
        self.accessToken = accessToken
        self.expiredAt = expiredAt
    }
}

// MARK: - File List
