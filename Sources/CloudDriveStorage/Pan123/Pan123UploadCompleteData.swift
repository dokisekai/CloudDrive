import Foundation
import CloudDriveContracts
import CloudDriveSupport

public struct Pan123UploadCompleteData: Codable, Sendable {
    public let completed: Bool
    public let fileID: Int64
    
    public init(completed: Bool, fileID: Int64) {
        self.completed = completed
        self.fileID = fileID
    }
}

// MARK: - File Operations (Move, Rename, Delete, Copy, Detail)
