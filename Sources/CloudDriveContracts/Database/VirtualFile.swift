import Foundation

public struct VirtualFile: Sendable, Equatable {
    public let id: String
    public let name: String
    public let parentId: String
    public let size: Int64
    public let encryptedName: String
    public let remotePath: String
    public let createdAt: Date
    public let modifiedAt: Date
    
    public init(
        id: String,
        name: String,
        parentId: String,
        size: Int64,
        encryptedName: String,
        remotePath: String,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.size = size
        self.encryptedName = encryptedName
        self.remotePath = remotePath
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}
