import Foundation
import CloudDriveContracts
import CloudDriveSupport

enum WebDAVPathResolver {
    static func buildURL(for path: String, baseURL: URL?) throws -> URL {
        guard let baseURL = baseURL else {
            throw WebDAVError.notConfigured
        }
        guard ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""),
              baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil,
              !path.contains("\\"), !path.unicodeScalars.contains(where: { $0.value < 32 }) else { throw WebDAVError.invalidPath }
        let rootPath = baseURL.path
        guard !rootPath.contains("\\"), !rootPath.unicodeScalars.contains(where: { $0.value < 32 }),
              !rootPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              !(URLComponents(url: baseURL, resolvingAgainstBaseURL: false)?.percentEncodedPath.lowercased().contains("%2f") ?? true),
              !(URLComponents(url: baseURL, resolvingAgainstBaseURL: false)?.percentEncodedPath.lowercased().contains("%5c") ?? true) else { throw WebDAVError.invalidPath }
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
        
        // 关键防御：如果 cleanPath 已经以 baseURL.path 为前缀，自动剥离前缀以防止路径重复追加
        var basePrefix = baseURL.path
        while basePrefix.hasPrefix("/") {
            basePrefix.removeFirst()
        }
        while basePrefix.hasSuffix("/") {
            basePrefix.removeLast()
        }
        
        if !basePrefix.isEmpty {
            if cleanPath == basePrefix {
                return baseURL
            } else if cleanPath.hasPrefix(basePrefix + "/") {
                cleanPath = String(cleanPath.dropFirst(basePrefix.count + 1))
            }
        }
        
        if cleanPath.isEmpty {
            return baseURL
        }
        
        let components = cleanPath.split(separator: "/").map(String.init)
        var resultURL = baseURL
        for comp in components {
            guard comp != "..", comp != "." else {
                throw WebDAVError.invalidPath
            }
            resultURL = resultURL.appendingPathComponent(comp)
        }
        return resultURL
    }
    
}
