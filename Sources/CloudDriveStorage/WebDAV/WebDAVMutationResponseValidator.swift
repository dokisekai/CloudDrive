import Foundation
import CloudDriveContracts
import CloudDriveSupport

enum WebDAVMutationResponseValidator {
    static func validate(statusCode: Int, data: Data) throws {
        guard statusCode == 207 else { return }
        
        final class MultiStatusMutationParser: NSObject, XMLParserDelegate {
            var firstFailureStatus: Int?
            var sawMultistatus = false
            var statusCount = 0
            private var depth = 0
            private var responseDepth: Int?
            private var responseStatuses = 0
            private var currentElement: String = ""
            private var currentValue: String = ""
            
            func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
                currentElement = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()
                depth += 1
                guard depth <= 64 else { parser.abortParsing(); return }
                if depth == 1 {
                    guard currentElement == "multistatus", namespaceURI == "DAV:" else { parser.abortParsing(); return }
                    sawMultistatus = true
                }
                if ["multistatus", "response", "status", "propstat"].contains(currentElement), namespaceURI != "DAV:" { parser.abortParsing(); return }
                if currentElement == "response" {
                    guard depth == 2, responseDepth == nil else { parser.abortParsing(); return }
                    responseDepth = depth
                    responseStatuses = 0
                }
                currentValue = ""
            }
            
            func parser(_ parser: XMLParser, foundCharacters string: String) {
                guard currentValue.utf8.count + string.utf8.count <= 1024 * 1024 else { parser.abortParsing(); return }
                currentValue += string
            }
            
            func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
                let localName = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()
                if localName == "status" {
                    guard responseDepth != nil else { parser.abortParsing(); return }
                    statusCount += 1
                    responseStatuses += 1
                    let text = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    let code = Int(text.split(separator: " ").dropFirst().first ?? "") ?? 0
                    if (!(200...299).contains(code)) && firstFailureStatus == nil {
                        firstFailureStatus = code == 0 ? 502 : code
                    }
                }
                if localName == "response" {
                    guard responseStatuses > 0 else { parser.abortParsing(); return }
                    responseDepth = nil
                }
                depth -= 1
                currentValue = ""
            }
        }
        
        try WebDAVXMLSafety.validate(data)
        let parser = XMLParser(data: data)
        let delegate = MultiStatusMutationParser()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = true
        guard parser.parse(), delegate.sawMultistatus, delegate.statusCount > 0 else { throw WebDAVError.parseError }
        if let failureCode = delegate.firstFailureStatus {
            throw StorageError.serverError(statusCode: failureCode, message: "WebDAV Multi-Status (207) contained failure code: \(failureCode)")
        }
    }
    
}
