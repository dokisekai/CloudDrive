import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit
import UniformTypeIdentifiers

extension S3StorageClient {
    // MARK: - XML Parser Helper
    
    public func parseS3ListObjectsV2Page(xmlData: Data, prefix: String) -> (resources: [StorageResource], isTruncated: Bool, nextContinuationToken: String?) {
        var results: [StorageResource] = []
        guard let xmlString = String(data: xmlData, encoding: .utf8) else {
            return (results, false, nil)
        }
        
        let isTruncated = extractTag(from: xmlString, tag: "IsTruncated")?.lowercased() == "true"
        let nextContinuationToken = extractTag(from: xmlString, tag: "NextContinuationToken")
        
        // 解析 <CommonPrefixes><Prefix>subfolder/</Prefix></CommonPrefixes>
        let prefixPattern = "<CommonPrefixes>\\s*<Prefix>(.*?)</Prefix>\\s*</CommonPrefixes>"
        if let regex = try? NSRegularExpression(pattern: prefixPattern, options: []) {
            let matches = regex.matches(in: xmlString, range: NSRange(xmlString.startIndex..., in: xmlString))
            for match in matches {
                if let r = Range(match.range(at: 1), in: xmlString) {
                    let dirPrefix = String(xmlString[r])
                    let trimmed = dirPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let name = (trimmed as NSString).lastPathComponent
                    let vfsPath = "/" + trimmed
                    results.append(StorageResource(
                        path: vfsPath,
                        displayName: name,
                        isDirectory: true,
                        contentLength: 0
                    ))
                }
            }
        }
        
        // 解析 <Contents><Key>...</Key><Size>...</Size><LastModified>...</LastModified><ETag>...</ETag></Contents>
        let contentsPattern = "<Contents>(.*?)</Contents>"
        if let regex = try? NSRegularExpression(pattern: contentsPattern, options: [.dotMatchesLineSeparators]) {
            let matches = regex.matches(in: xmlString, range: NSRange(xmlString.startIndex..., in: xmlString))
            for match in matches {
                if let r = Range(match.range(at: 1), in: xmlString) {
                    let contentBlock = String(xmlString[r])
                    let key = extractTag(from: contentBlock, tag: "Key") ?? ""
                    let sizeStr = extractTag(from: contentBlock, tag: "Size") ?? "0"
                    let etag = extractTag(from: contentBlock, tag: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    let lastModStr = extractTag(from: contentBlock, tag: "LastModified")
                    
                    // 过滤自身占位符和目录标记
                    if key.isEmpty || key == prefix || key.hasSuffix("/") {
                        continue
                    }
                    
                    let size = Int64(sizeStr) ?? 0
                    let cleanKey = key.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let name = (cleanKey as NSString).lastPathComponent
                    let vfsPath = "/" + cleanKey
                    
                    var modDate: Date? = nil
                    if let lm = lastModStr {
                        modDate = ISO8601DateFormatter().date(from: lm)
                    }
                    
                    results.append(StorageResource(
                        path: vfsPath,
                        displayName: name,
                        isDirectory: false,
                        contentLength: size,
                        lastModified: modDate,
                        etag: etag
                    ))
                }
            }
        }
        
        return (results, isTruncated, nextContinuationToken)
    }
    
    internal func parseS3ListObjectsV2(xmlData: Data, prefix: String) -> [StorageResource] {
        return parseS3ListObjectsV2Page(xmlData: xmlData, prefix: prefix).resources
    }
    
    func extractTag(from xml: String, tag: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"),
              let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex) else {
            return nil
        }
        return String(xml[start.upperBound..<end.lowerBound])
    }
}
