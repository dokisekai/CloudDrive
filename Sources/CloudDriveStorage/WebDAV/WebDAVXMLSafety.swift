import Foundation
import CloudDriveContracts

enum WebDAVXMLSafety {
    static func validate(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 64 * 1024 * 1024 else { throw WebDAVError.parseError }
        // XML declaration keywords are ASCII in UTF-8/16/32. Removing zero
        // bytes detects DTDs in every supported byte order without relying on
        // a guessed String encoding or expanding entities during parsing.
        let markup = Data(data.filter { $0 != 0 })
        guard markup.range(of: Data("<!DOCTYPE".utf8)) == nil,
              markup.range(of: Data("<!ENTITY".utf8)) == nil else { throw WebDAVError.parseError }
    }
}
