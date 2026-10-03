import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit
import UniformTypeIdentifiers

extension Pan123StorageClient {
    // MARK: - Path Normalization
    
    /// 规范化逻辑路径为以 / 开头、无末尾多余斜杠的路径
    func normalizePath(_ path: String) -> String {
        var clean = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty || clean == "/" {
            return "/"
        }
        while clean.contains("//") {
            clean = clean.replacingOccurrences(of: "//", with: "/")
        }
        if !clean.hasPrefix("/") {
            clean = "/" + clean
        }
        if clean.count > 1 && clean.hasSuffix("/") {
            clean.removeLast()
        }
        return clean
    }
}
