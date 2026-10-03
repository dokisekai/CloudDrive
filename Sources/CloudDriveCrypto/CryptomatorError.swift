import CloudDriveContracts
import CloudDriveSupport
import Foundation
public enum CryptomatorError: Error {
    case invalidDirId
    case invalidCiphertextName
    case networkError(Error)
    case notFound
    case corruptedVault
}

