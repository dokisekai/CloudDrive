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
        addAuthentication(to: &request)
        
        let (data, response) = try await WebDAVRetryPolicy.perform { try await boundedResponse(for: request) }
        
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
        try await resource(path: path) != nil
    }

    /// A Depth: 0 response must describe exactly the requested object.
    func resource(path: String) async throws -> WebDAVResource? {
        let url = try buildURL(for: path)
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("<D:propfind xmlns:D=\"DAV:\"><D:prop><D:resourcetype/><D:getetag/><D:getcontentlength/></D:prop></D:propfind>".utf8)
        addAuthentication(to: &request)
        let (data, response) = try await WebDAVRetryPolicy.perform { try await boundedResponse(for: request) }
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse }
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else { throw WebDAVError.serverError(http.statusCode) }
        let resources = try WebDAVXMLParser().parse(data: data, basePath: path, baseURL: baseURL, excludingSelf: false)
        func normalize(_ path: String) -> String { path == "/" ? path : path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        guard resources.count == 1, normalize(resources[0].path) == normalize(url.path) else { throw WebDAVError.invalidResponse }
        return resources[0]
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
        // Bound probing tasks as well as sockets for very large collections.
        for offset in stride(from: 0, to: folderResources.count, by: 8) {
        try await withThrowingTaskGroup(of: RemoteFolderItem.self) { group in
            for folder in folderResources[offset..<min(offset + 8, folderResources.count)] {
                let name = folder.displayName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let folderPath: String
                if cleanPath == "/" {
                    folderPath = "/\(name)"
                } else {
                    folderPath = "\(cleanPath)/\(name)"
                }
                
                group.addTask {
                    // 快速轻量检测该子目录是否也是一个加密保险库（并发探测）
                    let hasMK = (try? await self.exists(path: "\(folderPath)/masterkey.cryptomator")) ?? false
                    let hasSalt = hasMK ? false : ((try? await self.exists(path: "\(folderPath)/salt")) ?? false)
                    let isVault = hasMK || hasSalt
                    return RemoteFolderItem(path: folderPath, name: name.isEmpty ? folderPath : name, isVault: isVault)
                }
            }
            
            for try await item in group {
                folders.append(item)
            }
        }
        
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
