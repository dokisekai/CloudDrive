import Foundation
import CloudDriveContracts
import CloudDriveSupport

extension WebDAVClient {
    public func listDirectory(path: String) async throws -> [WebDAVResource] {
        let url = try buildURL(for: path)
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        
        // PROPFIND XML body
        let propfindXML = """
        <?xml version="1.0" encoding="utf-8" ?>
        <D:propfind xmlns:D="DAV:">
            <D:prop>
                <D:displayname/>
                <D:getcontentlength/>
                <D:getcontenttype/>
                <D:creationdate/>
                <D:getlastmodified/>
                <D:resourcetype/>
                <D:getetag/>
            </D:prop>
        </D:propfind>
        """
        request.httpBody = propfindXML.data(using: .utf8)
        
        // 添加认证
        if let credentials = credentials {
            let authString = "\(credentials.user!):\(credentials.password!)"
            if let authData = authString.data(using: .utf8) {
                let base64Auth = authData.base64EncodedString()
                request.setValue("Basic \(base64Auth)", forHTTPHeaderField: "Authorization")
            }
        }
        
        let (data, response) = try await WebDAVRetryPolicy.perform { try await session.data(for: request) }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebDAVError.serverError(httpResponse.statusCode)
        }
        
        // 解析 XML 响应
        return try WebDAVXMLParser().parse(data: data, basePath: path, baseURL: baseURL)
    }
    
    /// 检查资源是否存在（PROPFIND Depth: 0）
    public func exists(path: String) async throws -> Bool {
        let url = try buildURL(for: path)
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        
        let propfindXML = """
        <?xml version="1.0" encoding="utf-8" ?>
        <D:propfind xmlns:D="DAV:">
            <D:prop>
                <D:resourcetype/>
            </D:prop>
        </D:propfind>
        """
        request.httpBody = propfindXML.data(using: .utf8)
        
        if let credentials = credentials {
            let authString = "\(credentials.user!):\(credentials.password!)"
            if let authData = authString.data(using: .utf8) {
                let base64Auth = authData.base64EncodedString()
                request.setValue("Basic \(base64Auth)", forHTTPHeaderField: "Authorization")
            }
        }
        
        let (data, response) = try await WebDAVRetryPolicy.perform { try await session.data(for: request) }
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse }
        if http.statusCode == 404 { return false }
        guard (200...299).contains(http.statusCode) else { throw WebDAVError.serverError(http.statusCode) }
        if http.statusCode == 207 { _ = try WebDAVXMLParser().parse(data: data, basePath: path, baseURL: baseURL) }
        return true
    }
    
    /// 浏览指定路径下的子目录，并检测当前目录和子目录是否包含加密保险库
    public func browseDirectory(path: String) async throws -> (currentIsVault: Bool, folders: [RemoteFolderItem]) {
        var cleanPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanPath.isEmpty || cleanPath == "/" {
            cleanPath = "/"
        } else {
            if !cleanPath.hasPrefix("/") {
                cleanPath = "/" + cleanPath
            }
            while cleanPath.hasSuffix("/") && cleanPath.count > 1 {
                cleanPath = String(cleanPath.dropLast())
            }
        }
        
        let resources = try await listDirectory(path: cleanPath)
        
        var currentIsVault = false
        var folderResources: [WebDAVResource] = []
        
        for res in resources {
            let name = res.displayName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if name == "masterkey.cryptomator" || name == "salt" || name == "vault.cryptomator" {
                currentIsVault = true
            }
            if res.isDirectory {
                if !name.isEmpty && name != "d" && name != "f" && !name.hasPrefix(".") {
                    folderResources.append(res)
                }
            }
        }
        
        var folders: [RemoteFolderItem] = []
        for folder in folderResources {
            let name = folder.displayName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let folderPath: String
            if cleanPath == "/" {
                folderPath = "/\(name)"
            } else {
                folderPath = "\(cleanPath)/\(name)"
            }
            
            // 快速轻量检测该子目录是否也是一个加密保险库
            let hasMK = (try? await exists(path: "\(folderPath)/masterkey.cryptomator")) ?? false
            let hasSalt = hasMK ? false : ((try? await exists(path: "\(folderPath)/salt")) ?? false)
            let isVault = hasMK || hasSalt
            
            folders.append(RemoteFolderItem(path: folderPath, name: name.isEmpty ? folderPath : name, isVault: isVault))
        }
        
        // 按照名称排序，保险库置顶
        folders.sort { a, b in
            if a.isVault != b.isVault {
                return a.isVault && !b.isVault
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        
        return (currentIsVault, folders)
    }
    
    /// Downloaded bytes are staged before replacing an existing local file.
}
