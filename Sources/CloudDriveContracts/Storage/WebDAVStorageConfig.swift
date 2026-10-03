import Foundation

public struct WebDAVStorageConfig: Codable, Hashable, Sendable {
    public var baseURL: String
    public var username: String
    public var password: String
    
    public init(baseURL: String, username: String, password: String) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
    }
}
