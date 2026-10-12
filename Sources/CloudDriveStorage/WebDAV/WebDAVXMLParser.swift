import Foundation
import CloudDriveContracts
import CloudDriveSupport

final class WebDAVXMLParser: NSObject, XMLParserDelegate {
    private let isoDateFormatter = ISO8601DateFormatter()
    private let rfcDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
    private var baseURL: URL?
    private var resources: [WebDAVResource] = []
    private var currentResource: [String: String] = [:]
    private var currentElement: String = ""
    private var currentValue: String = ""
    private var propstat: [String: String]?
    private var sawMultistatus = false
    private var depth = 0
    private var responseFailure: Int?
    private var failure: Int?
    
    func parse(data: Data, basePath: String, baseURL: URL? = nil, excludingSelf: Bool = true) throws -> [WebDAVResource] {
        try WebDAVXMLSafety.validate(data)
        self.baseURL = baseURL
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = true
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
            } else if normalizedBase != cleanPrefix && !normalizedBase.hasPrefix(cleanPrefix + "/") {
                normalizedBase = normalize(cleanPrefix + normalizedBase)
            }
        }
        
        // A Depth: 1 snapshot must never inject siblings, parents, or descendants.
        var seen = Set<String>()
        for resource in resources {
            let candidate = normalize(resource.path)
            let components = candidate.split(separator: "/")
            guard !components.contains("."), !components.contains(".."),
                  !candidate.contains("\\"), !candidate.unicodeScalars.contains(where: { $0.value < 32 }),
                  seen.insert(candidate).inserted else { throw WebDAVError.parseError }
            if candidate != normalizedBase {
                let prefix = normalizedBase == "/" ? "/" : normalizedBase + "/"
                guard candidate.hasPrefix(prefix), !candidate.dropFirst(prefix.count).contains("/") else { throw WebDAVError.parseError }
            }
        }
        return excludingSelf ? resources.filter { normalize($0.path) != normalizedBase } : resources
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let localName = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()
        depth += 1
        guard depth <= 64 else { parser.abortParsing(); return }
        if depth == 1 {
            guard localName == "multistatus", namespaceURI == "DAV:" else { parser.abortParsing(); return }
            sawMultistatus = true
        }
        let davNames: Set<String> = ["multistatus", "response", "propstat", "prop", "href", "status", "displayname", "getcontentlength", "getcontenttype", "creationdate", "getlastmodified", "getetag", "resourcetype", "collection"]
        if davNames.contains(localName), namespaceURI != "DAV:" { parser.abortParsing(); return }
        currentElement = localName
        currentValue = ""
        

        if localName == "response" {
            currentResource = [:]
            responseFailure = nil
        }
        if localName == "propstat" { propstat = [:] }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentValue.utf8.count + string.utf8.count <= 1024 * 1024 else { parser.abortParsing(); return }
        currentValue += string
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let localName = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()
        depth -= 1
        
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
                guard let components = URLComponents(string: href), components.query == nil, components.fragment == nil else { failure = 502; break }
                if let host = components.host {
                    guard let baseURL, host.lowercased() == baseURL.host?.lowercased(),
                          components.scheme?.lowercased() == baseURL.scheme?.lowercased(),
                          (components.port ?? (components.scheme == "https" ? 443 : 80)) == (baseURL.port ?? (baseURL.scheme == "https" ? 443 : 80)) else { failure = 502; break }
                }
                let encodedPath = components.percentEncodedPath
                guard !encodedPath.lowercased().contains("%2f"), !encodedPath.lowercased().contains("%5c"),
                      encodedPath.removingPercentEncoding != nil else { failure = 502; break }
                let cleanHref = encodedPath.removingPercentEncoding ?? encodedPath
                let resource = WebDAVResource(
                    path: cleanHref,
                    displayName: cleanHref.split(separator: "/").last.map(String.init) ?? "",
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
        
        if let date = isoDateFormatter.date(from: dateString) { return date }
        return rfcDateFormatter.date(from: dateString)
    }
}
