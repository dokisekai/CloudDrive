import Foundation

public struct VirtualDirectory: Sendable, Equatable {
    public let id: String
    public let name: String
    public let parentId: String?
    public let encryptedId: String
    public let remotePath: String
    public let createdAt: Date
    public let modifiedAt: Date
    
    public init(
        id: String,
        name: String,
        parentId: String?,
        encryptedId: String,
        remotePath: String,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.encryptedId = encryptedId
        self.remotePath = remotePath
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

