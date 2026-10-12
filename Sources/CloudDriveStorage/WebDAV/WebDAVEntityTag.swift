import Foundation
import CloudDriveContracts

enum WebDAVEntityTag {
    static func strong(_ value: String) throws -> String {
        let tag = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // If-Match requires strong comparison. Never fabricate a strong validator
        // from W/: two different byte representations can share a weak validator.
        guard tag.count >= 2, tag.first == "\"", tag.last == "\"",
              !tag.dropFirst().dropLast().contains("\""),
              !tag.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7f }) else {
            throw StorageError.serverError(statusCode: 412, message: "A strong ETag is required for a conditional mutation")
        }
        return tag
    }
}
