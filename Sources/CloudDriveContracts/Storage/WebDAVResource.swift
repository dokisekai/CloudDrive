import Foundation

public struct WebDAVResource {
    public let path: String
    public let displayName: String
    public let isDirectory: Bool
    public let contentLength: Int64
    public let contentType: String?
    public let creationDate: Date?
    public let lastModified: Date?
    public let etag: String?
    
    public init(path: String, displayName: String, isDirectory: Bool, contentLength: Int64,
                contentType: String?, creationDate: Date?, lastModified: Date?, etag: String?) {
        self.path = path
        self.displayName = displayName
        self.isDirectory = isDirectory
        self.contentLength = contentLength
        self.contentType = contentType
        self.creationDate = creationDate
        self.lastModified = lastModified
        self.etag = etag
    }
}
