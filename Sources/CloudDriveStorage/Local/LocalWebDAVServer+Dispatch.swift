import Foundation
import CloudDriveContracts
import CloudDriveSupport
import Network

extension LocalWebDAVServer {
    // MARK: - 请求分发与 WebDAV 处理
    
    func processRequest(headerStr: String, headers: [String: String], body: Data, connection: NWConnection) {
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse(connection: connection, status: "400 Bad Request", headers: [:], body: nil)
            return
        }
        
        let reqParts = requestLine.split(separator: " ")
        guard reqParts.count >= 2 else {
            sendResponse(connection: connection, status: "400 Bad Request", headers: [:], body: nil)
            return
        }
        
        let method = String(reqParts[0]).uppercased()
        let rawPath = String(reqParts[1])
        
        // 解析 URL 路径获取 vaultId 与子路径
        guard let (vaultId, subPath) = resolveVaultRouting(path: rawPath) else {
            sendResponse(connection: connection, status: "404 Not Found", headers: ["Content-Length": "0"], body: nil)
            return
        }
        
        lock.lock()
        let localBaseURL = registeredVaults[vaultId] ?? registeredVaults.values.first
        lock.unlock()
        
        guard let baseURL = localBaseURL else {
            logError(.system, "❌ LocalWebDAV: Vault directory not found (vaultId: \(vaultId))")
            sendResponse(connection: connection, status: "404 Not Found", headers: ["Content-Length": "0"], body: nil)
            return
        }
        
        let hasAccess = baseURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                baseURL.stopAccessingSecurityScopedResource()
            }
        }
        
        let targetLocalURL: URL
        if subPath.isEmpty || subPath == "/" {
            targetLocalURL = baseURL
        } else {
            let cleanSub = subPath.hasPrefix("/") ? String(subPath.dropFirst()) : subPath
            var url = baseURL
            for comp in cleanSub.split(separator: "/") {
                url = url.appendingPathComponent(String(comp))
            }
            targetLocalURL = url
        }
        
        let fm = FileManager.default
        let pathStr = targetLocalURL.path
        
        switch method {
        case "OPTIONS":
            sendResponse(connection: connection, status: "200 OK", headers: [
                "DAV": "1, 2",
                "Allow": "OPTIONS, GET, HEAD, POST, PUT, DELETE, PROPFIND, PROPPATCH, MKCOL, COPY, MOVE",
                "MS-Author-Via": "DAV",
                "Content-Length": "0"
            ], body: nil)
            
        case "PROPFIND":
            let depth = headers["depth"] ?? "1"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: pathStr, isDirectory: &isDir) else {
                sendResponse(connection: connection, status: "404 Not Found", headers: ["Content-Length": "0"], body: nil)
                return
            }
            
            let xml = buildPropfindXML(baseURLPath: rawPath, localURL: targetLocalURL, isDirectory: isDir.boolValue, depth: depth)
            let xmlData = xml.data(using: .utf8) ?? Data()
            sendResponse(connection: connection, status: "207 Multi-Status", headers: [
                "Content-Type": "application/xml; charset=utf-8",
                "Content-Length": "\(xmlData.count)"
            ], body: xmlData)
            
        case "GET":
            handleGet(localURL: targetLocalURL, headers: headers, isHead: false, connection: connection)
            
        case "HEAD":
            handleGet(localURL: targetLocalURL, headers: headers, isHead: true, connection: connection)
            
        case "PUT":
            do {
                try fm.createDirectory(at: targetLocalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try body.write(to: targetLocalURL, options: .atomic)
                sendResponse(connection: connection, status: "201 Created", headers: ["Content-Length": "0"], body: nil)
            } catch {
                logError(.system, "❌ LocalWebDAV PUT write failed: \(error)")
                sendResponse(connection: connection, status: "500 Internal Server Error", headers: ["Content-Length": "0"], body: nil)
            }
            
        case "MKCOL":
            do {
                try fm.createDirectory(at: targetLocalURL, withIntermediateDirectories: true)
                sendResponse(connection: connection, status: "201 Created", headers: ["Content-Length": "0"], body: nil)
            } catch {
                logError(.system, "❌ LocalWebDAV MKCOL create directory failed: \(error)")
                sendResponse(connection: connection, status: "500 Internal Server Error", headers: ["Content-Length": "0"], body: nil)
            }
            
        case "DELETE":
            do {
                if fm.fileExists(atPath: pathStr) {
                    try fm.removeItem(at: targetLocalURL)
                }
                sendResponse(connection: connection, status: "204 No Content", headers: ["Content-Length": "0"], body: nil)
            } catch {
                logError(.system, "❌ LocalWebDAV DELETE failed: \(error)")
                sendResponse(connection: connection, status: "500 Internal Server Error", headers: ["Content-Length": "0"], body: nil)
            }
            
        case "MOVE":
            handleMoveOrCopy(localURL: targetLocalURL, headers: headers, isMove: true, connection: connection)
            
        case "COPY":
            handleMoveOrCopy(localURL: targetLocalURL, headers: headers, isMove: false, connection: connection)
            
        default:
            sendResponse(connection: connection, status: "200 OK", headers: ["Content-Length": "0"], body: nil)
        }
    }
}
