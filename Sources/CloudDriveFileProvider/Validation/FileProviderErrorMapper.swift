//
//  FileProviderErrorMapper.swift
//  CloudDriveFileProvider
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  底层错误向系统 NSFileProviderError 的跨域转译器
//

import Foundation
import FileProvider
import CloudDriveCore

/// Maps underlying errors to system expected NSFileProviderError
func mapToFileProviderError(_ error: Error) -> NSFileProviderError {
    logInfo(.fileOps, "🔄 FileProvider: Mapping error to NSFileProviderError")
    logError(.fileOps, "Error: \(error)")
    
    if let fpError = error as? NSFileProviderError {
        return fpError
    }
    
    if let urlError = error as? URLError {
        switch urlError.code {
        case .notConnectedToInternet, .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost:
            return NSFileProviderError(.serverUnreachable)
        default:
            return NSFileProviderError(.serverUnreachable)
        }
    }
    
    if let storageError = error as? StorageError {
        switch storageError {
        case .notConfigured: return NSFileProviderError(.providerNotFound)
        case .notFound: return NSFileProviderError(.noSuchItem)
        case .invalidOperation: return NSFileProviderError(.filenameCollision)
        case .fileSystemError: return NSFileProviderError(.serverUnreachable)
        case .permissionDenied, .authenticationFailed: return NSFileProviderError(.notAuthenticated)
        case .indeterminateMutation: return NSFileProviderError(.cannotSynchronize)
        case .networkError: return NSFileProviderError(.serverUnreachable)
        case .serverError(let statusCode, _):
            if statusCode == 412 { return NSFileProviderError(.filenameCollision) }
            return NSFileProviderError(.serverUnreachable)
        case .notSupported: return NSFileProviderError(.noSuchItem)
        @unknown default: return NSFileProviderError(.serverUnreachable)
        }
    }
    
    if let vfsError = error as? VFSError {
        switch vfsError {
        case .vaultLocked, .invalidPassword: return NSFileProviderError(.notAuthenticated)
        case .parentNotFound, .fileNotFound, .itemNotFound, .invalidPath, .vaultNotFound: return NSFileProviderError(.noSuchItem)
        case .encryptionFailed, .decryptionFailed, .directoryCreationFailed: return NSFileProviderError(.serverUnreachable)
        case .fileOperationFailed(let msg):
            if msg.contains("412") || msg.contains("collision") || msg.contains("invalidOperation") {
                return NSFileProviderError(.filenameCollision)
            }
            return NSFileProviderError(.serverUnreachable)
        case .databaseError, .networkError: return NSFileProviderError(.serverUnreachable)
        case .authenticationFailed: return NSFileProviderError(.notAuthenticated)
        case .storageNotConfigured: return NSFileProviderError(.providerNotFound)
        case .vaultAlreadyExists: return NSFileProviderError(.filenameCollision)
        @unknown default: return NSFileProviderError(.serverUnreachable)
        }
    }
    
    if let webDavError = error as? WebDAVError {
        switch webDavError {
        case .notConfigured: return NSFileProviderError(.providerNotFound)
        case .invalidResponse, .parseError: return NSFileProviderError(.serverUnreachable)
        case .serverError(let code):
            if code == 404 { return NSFileProviderError(.noSuchItem) }
            else if code == 401 || code == 403 { return NSFileProviderError(.notAuthenticated) }
            else if code == 409 { return NSFileProviderError(.serverUnreachable) }
            else if code == 412 { return NSFileProviderError(.filenameCollision) }
            else if code == 423 { return NSFileProviderError(.serverUnreachable) }
            return NSFileProviderError(.serverUnreachable)
        case .authenticationFailed: return NSFileProviderError(.notAuthenticated)
        case .fileNotFound: return NSFileProviderError(.noSuchItem)
        case .notConnectedToInternet, .timeout: return NSFileProviderError(.serverUnreachable)
        @unknown default: return NSFileProviderError(.serverUnreachable)
        }
    }
    
    if let cryptoError = error as? CryptomatorError {
        switch cryptoError {
        case .notFound: return NSFileProviderError(.noSuchItem)
        case .networkError: return NSFileProviderError(.serverUnreachable)
        case .invalidDirId, .invalidCiphertextName, .corruptedVault: return NSFileProviderError(.serverUnreachable)
        @unknown default: return NSFileProviderError(.serverUnreachable)
        }
    }
    
    let errorString = String(describing: error)
    if errorString.contains("notConnectedToInternet") || errorString.contains("timeout") || errorString.contains("timedOut") {
        return NSFileProviderError(.serverUnreachable)
    }
    
    return NSFileProviderError(.serverUnreachable)
}
