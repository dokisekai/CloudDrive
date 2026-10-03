//
//  VFSError.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  虚拟文件系统领域错误定义
//

import Foundation

public enum VFSError: Error, LocalizedError {
    case vaultLocked
    case parentNotFound
    case fileNotFound
    case itemNotFound
    case encryptionFailed
    case decryptionFailed
    case invalidPassword
    case vaultNotFound(String)
    case vaultAlreadyExists(String)
    case databaseError(String)
    case invalidPath
    case networkError
    case authenticationFailed
    case storageNotConfigured
    case directoryCreationFailed(String)
    case fileOperationFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .vaultLocked:
            return "Vault is locked"
        case .parentNotFound:
            return "Parent directory not found"
        case .fileNotFound:
            return "File not found"
        case .itemNotFound:
            return "Item not found"
        case .encryptionFailed:
            return "Encryption failed"
        case .decryptionFailed:
            return "Decryption failed"
        case .invalidPassword:
            return "Invalid vault password, unable to unlock"
        case .vaultNotFound(let path):
            return "No valid encrypted vault files found at path '\(path)' (masterkey.cryptomator or salt)"
        case .vaultAlreadyExists(let path):
            return "A vault already exists at path '\(path)'. Creation aborted to prevent overwriting existing keys."
        case .databaseError(let detail):
            return "Database error: \(detail)"
        case .invalidPath:
            return "Invalid path"
        case .networkError:
            return "Network error"
        case .authenticationFailed:
            return "Authentication failed"
        case .storageNotConfigured:
            return "Storage not configured"
        case .directoryCreationFailed(let detail):
            return "Directory creation failed: \(detail)"
        case .fileOperationFailed(let detail):
            return "File operation failed: \(detail)"
        }
    }
}
