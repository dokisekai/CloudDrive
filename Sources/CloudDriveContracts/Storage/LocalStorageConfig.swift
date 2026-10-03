import Foundation

public struct LocalStorageConfig: Codable, Hashable, Sendable {
    public var path: String
    public var bookmarkData: Data?
    
    public init(path: String, bookmarkData: Data? = nil) {
        self.path = path
        self.bookmarkData = bookmarkData
    }
}
