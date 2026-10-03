import Foundation
import CloudDriveContracts
import CloudDriveSupport

enum WebDAVMutationResponseValidator {
    static func validate(statusCode: Int, data: Data) throws {
        guard statusCode == 207 else { return }
        
        final class MultiStatusMutationParser: NSObject, XMLParserDelegate {
            var firstFailureStatus: Int?
            private var currentElement: String = ""
            private var currentValue: String = ""
            
            func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
                currentElement = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()
                currentValue = ""
            }
            
            func parser(_ parser: XMLParser, foundCharacters string: String) {
                currentValue += string
            }
            
            func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
                let localName = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()
                if localName == "status" {
                    let text = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    let code = Int(text.split(separator: " ").dropFirst().first ?? "") ?? 0
                    if (code >= 400 || code == 0) && firstFailureStatus == nil {
                        firstFailureStatus = code == 0 ? 502 : code
                    }
                }
                currentValue = ""
            }
        }
        
        guard !data.isEmpty else { return }
        let parser = XMLParser(data: data)
        let delegate = MultiStatusMutationParser()
        parser.delegate = delegate
        if parser.parse(), let failureCode = delegate.firstFailureStatus {
            throw StorageError.serverError(statusCode: failureCode, message: "WebDAV Multi-Status (207) contained failure code: \(failureCode)")
        }
    }
    
}
