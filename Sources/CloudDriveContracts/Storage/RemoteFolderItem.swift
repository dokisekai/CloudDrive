import Foundation

public struct RemoteFolderItem: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let isVault: Bool
    
    public init(path: String, name: String, isVault: Bool = false) {
        self.path = path
        self.name = name
        self.isVault = isVault
    }
}
