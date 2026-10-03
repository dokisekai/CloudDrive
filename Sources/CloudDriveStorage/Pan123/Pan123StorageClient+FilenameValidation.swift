import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit
import UniformTypeIdentifiers

extension Pan123StorageClient {
    // MARK: - Filename Validation
    
    /// 校验文件名/目录名是否符合 123云盘开放平台约束
    public static func validateFilename(_ filename: String) throws {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw StorageError.notSupported("文件名或目录名不能为空或全为空格")
        }
        if filename.hasPrefix(" ") || filename.hasSuffix(" ") {
            throw StorageError.notSupported("文件名不能以空格开头或结尾: '\(filename)'")
        }
        if filename.count >= 255 {
            throw StorageError.notSupported("文件名长度超过 123云盘 255 字符限制: '\(filename)'")
        }
        if filename.rangeOfCharacter(from: illegalFilenameCharacters) != nil {
            throw StorageError.notSupported("文件名包含 123云盘不支持的特殊字符 (\\ / : * ? \" < > |): '\(filename)'")
        }
    }
}
