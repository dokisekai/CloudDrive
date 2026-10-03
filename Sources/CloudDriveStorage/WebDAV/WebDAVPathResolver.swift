import Foundation
import CloudDriveContracts
import CloudDriveSupport

enum WebDAVPathResolver {
    static func buildURL(for path: String, baseURL: URL?) throws -> URL {
        guard let baseURL = baseURL else {
            throw WebDAVError.notConfigured
        }
        var cleanPath = path
        while cleanPath.hasPrefix("/") {
            cleanPath.removeFirst()
        }
        while cleanPath.hasSuffix("/") {
            cleanPath.removeLast()
        }
        if cleanPath.isEmpty {
            return baseURL
        }
        let components = cleanPath.split(separator: "/").map(String.init)
        var resultURL = baseURL
        for comp in components {
            resultURL = resultURL.appendingPathComponent(comp)
        }
        return resultURL
    }
    
}
