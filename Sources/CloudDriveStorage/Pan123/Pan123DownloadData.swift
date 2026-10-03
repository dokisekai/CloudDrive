import Foundation
import CloudDriveContracts
import CloudDriveSupport

public struct Pan123DownloadData: Codable, Sendable {
    public let downloadUrl: String
    
    public init(downloadUrl: String) {
        self.downloadUrl = downloadUrl
    }
}

// MARK: - Upload (V2)
