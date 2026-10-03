import Foundation
import CloudDriveContracts
import CloudDriveSupport

final class WebDAVXMLParser: NSObject, XMLParserDelegate {
    private var resources: [WebDAVResource] = []
    private var currentResource: [String: String] = [:]
    private var currentElement: String = ""
    private var currentValue: String = ""
    private var propstat: [String: String]?
    private var sawMultistatus = false
    private var responseFailure: Int?
    private var failure: Int?
    
    func parse(data: Data, basePath: String, baseURL: URL? = nil) throws -> [WebDAVResource] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        
        guard parser.parse(), sawMultistatus else { throw WebDAVError.parseError }
        if let failure = failure { throw WebDAVError.serverError(failure) }
        guard !resources.isEmpty else { throw WebDAVError.parseError }
        
        func normalize(_ p: String) -> String {
            var s = p
            if !s.hasPrefix("/") { s = "/" + s }
            while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
            return s
        }
        
        var normalizedBase = normalize(basePath)
        if let basePrefix = baseURL?.path, !basePrefix.isEmpty && basePrefix != "/" {
            let cleanPrefix = normalize(basePrefix)
            if normalizedBase == "/" {
                normalizedBase = cleanPrefix
            } else if !normalizedBase.hasPrefix(cleanPrefix) {
                normalizedBase = normalize(cleanPrefix + normalizedBase)
            }
        }
        
        // 过滤掉当前目录自身
        return resources.filter { resource in
            let normPath = normalize(resource.path)
            return normPath != normalizedBase
        }
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let localName = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()
        currentElement = localName
        currentValue = ""
        
        if localName == "multistatus" { sawMultistatus = true }
        if localName == "response" {
            currentResource = [:]
            responseFailure = nil
        }
        if localName == "propstat" { propstat = [:] }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentValue += string
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let localName = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()
        
        let value = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch localName {
        case "href":
            currentResource["href"] = value
        case "status":
            let code = Int(value.split(separator: " ").dropFirst().first ?? "") ?? 0
            if propstat != nil { propstat?["status"] = String(code) }
            else if !(200...299).contains(code) { responseFailure = code }
        case "displayname", "getcontentlength", "getcontenttype", "creationdate", "getlastmodified", "getetag":
            let keys = ["displayname": "displayname", "getcontentlength": "contentlength", "getcontenttype": "contenttype", "creationdate": "creationdate", "getlastmodified": "lastmodified", "getetag": "etag"]
            if let key = keys[localName] { propstat?[key] = localName == "displayname" ? currentValue : value }
        case "collection":
            propstat?["isdirectory"] = "true"
        case "propstat":
            if let properties = propstat, let code = Int(properties["status"] ?? ""), (200...299).contains(code) {
                for (key, value) in properties where key != "status" { currentResource[key] = value }
                currentResource["successful"] = "true"
            }
            propstat = nil
        case "response":
            if let responseFailure = responseFailure {
                failure = responseFailure
            } else if currentResource["successful"] != "true" {
                // An all-failed resource makes the snapshot incomplete; do not prune caches.
                failure = 502
            } else if let href = currentResource["href"] {
                let encodedPath = URLComponents(string: href)?.percentEncodedPath ?? href
                let cleanHref = encodedPath.removingPercentEncoding ?? encodedPath
                let resource = WebDAVResource(
                    path: cleanHref,
                    displayName: currentResource["displayname"]?.isEmpty == false ? currentResource["displayname"]! : (cleanHref.split(separator: "/").last.map(String.init) ?? ""),
                    isDirectory: currentResource["isdirectory"] == "true",
                    contentLength: Int64(currentResource["contentlength"] ?? "0") ?? 0,
                    contentType: currentResource["contenttype"],
                    creationDate: parseDate(currentResource["creationdate"]),
                    lastModified: parseDate(currentResource["lastmodified"]),
                    etag: currentResource["etag"]
                )
                resources.append(resource)
            } else { failure = 502 }
        default:
            break
        }

        currentValue = ""
    }
    
    private func parseDate(_ dateString: String?) -> Date? {
        guard let dateString = dateString else { return nil }
        
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: dateString) {
            return date
        }
        
        let rfc1123Formatter = DateFormatter()
        rfc1123Formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        rfc1123Formatter.locale = Locale(identifier: "en_US_POSIX")
        return rfc1123Formatter.date(from: dateString)
    }
}
