import Foundation
import CloudDriveContracts
import CloudDriveSupport
import Network

extension LocalWebDAVServer {
    func buildPropfindXML(baseURLPath: String, localURL: URL, isDirectory: Bool, depth: String) -> String {
        var items: [(href: String, name: String, isDir: Bool, size: Int64, date: Date)] = []
        let fm = FileManager.default
        let attrs = (try? fm.attributesOfItem(atPath: localURL.path)) ?? [:]
        let size = isDirectory ? 0 : (attrs[.size] as? Int64 ?? 0)
        let date = attrs[.modificationDate] as? Date ?? Date()
        
        // 1. 当前项自身
        let cleanBase = baseURLPath.hasSuffix("/") && baseURLPath.count > 1 ? String(baseURLPath.dropLast()) : baseURLPath
        items.append((cleanBase.isEmpty ? "/" : cleanBase, localURL.lastPathComponent, isDirectory, size, date))
        
        // 2. 子项目（当 Depth == "1" 时）
        if isDirectory && depth == "1" {
            if let contents = try? fm.contentsOfDirectory(at: localURL, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) {
                for child in contents {
                    var childIsDir: ObjCBool = false
                    fm.fileExists(atPath: child.path, isDirectory: &childIsDir)
                    let childAttrs = (try? fm.attributesOfItem(atPath: child.path)) ?? [:]
                    let childSize = childIsDir.boolValue ? 0 : (childAttrs[.size] as? Int64 ?? 0)
                    let childDate = childAttrs[.modificationDate] as? Date ?? Date()
                    let childHref = cleanBase.hasSuffix("/") ? "\(cleanBase)\(child.lastPathComponent)" : "\(cleanBase)/\(child.lastPathComponent)"
                    items.append((childHref, child.lastPathComponent, childIsDir.boolValue, childSize, childDate))
                }
            }
        }
        
        let rfc1123 = DateFormatter()
        rfc1123.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        rfc1123.locale = Locale(identifier: "en_US_POSIX")
        rfc1123.timeZone = TimeZone(secondsFromGMT: 0)
        
        var xml = "<?xml version=\"1.0\" encoding=\"utf-8\" ?>\n<D:multistatus xmlns:D=\"DAV:\">\n"
        for item in items {
            xml += "  <D:response>\n"
            xml += "    <D:href>\(item.href)</D:href>\n"
            xml += "    <D:propstat>\n"
            xml += "      <D:prop>\n"
            xml += "        <D:displayname>\(item.name)</D:displayname>\n"
            if item.isDir {
                xml += "        <D:resourcetype><D:collection/></D:resourcetype>\n"
                xml += "        <D:getcontentlength>0</D:getcontentlength>\n"
            } else {
                xml += "        <D:resourcetype/>\n"
                xml += "        <D:getcontentlength>\(item.size)</D:getcontentlength>\n"
            }
            xml += "        <D:getlastmodified>\(rfc1123.string(from: item.date))</D:getlastmodified>\n"
            xml += "      </D:prop>\n"
            xml += "      <D:status>HTTP/1.1 200 OK</D:status>\n"
            xml += "    </D:propstat>\n"
            xml += "  </D:response>\n"
        }
        xml += "</D:multistatus>"
        return xml
    }
}
