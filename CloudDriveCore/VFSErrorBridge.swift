//
//  VFSErrorBridge.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  VFS 错误桥接 - 将 VFSError 转换为 Foundation 错误
//

import Foundation

/// VFS 错误桥接器 - 确保错误域兼容性
public class VFSErrorBridge {
    
    /// 将 VFSError 转换为 NSError（使用 NSCocoaErrorDomain）
    public static func convertToNSError(_ vfsError: VFSError) -> NSError {
        let domain = NSCocoaErrorDomain
        let code: Int
        let userInfo: [String: Any]
        
        switch vfsError {
        case .vaultLocked:
            code = NSFileReadNoPermissionError
            userInfo = [
                NSLocalizedDescriptionKey: "保险库已锁定",
                NSLocalizedFailureReasonErrorKey: "需要解锁保险库才能访问"
            ]
            
        case .parentNotFound:
            code = NSFileNoSuchFileError
            userInfo = [
                NSLocalizedDescriptionKey: "父目录不存在",
                NSLocalizedFailureReasonErrorKey: "无法找到指定的父目录"
            ]
            
        case .fileNotFound:
            code = NSFileNoSuchFileError
            userInfo = [
                NSLocalizedDescriptionKey: "文件不存在",
                NSLocalizedFailureReasonErrorKey: "无法找到指定的文件"
            ]
            
        case .itemNotFound:
            code = NSFileNoSuchFileError
            userInfo = [
                NSLocalizedDescriptionKey: "项目不存在",
                NSLocalizedFailureReasonErrorKey: "无法找到指定的项目"
            ]
            
        case .encryptionFailed:
            code = NSFileWriteUnknownError
            userInfo = [
                NSLocalizedDescriptionKey: "加密失败",
                NSLocalizedFailureReasonErrorKey: "无法加密数据"
            ]
            
        case .decryptionFailed:
            code = NSFileReadUnknownError
            userInfo = [
                NSLocalizedDescriptionKey: "解密失败",
                NSLocalizedFailureReasonErrorKey: "无法解密数据"
            ]
            
        case .databaseError(let detail):
            code = NSFileReadUnknownError
            userInfo = [
                NSLocalizedDescriptionKey: "数据库错误",
                NSLocalizedFailureReasonErrorKey: detail
            ]
            
        case .invalidPath:
            code = NSFileNoSuchFileError
            userInfo = [
                NSLocalizedDescriptionKey: "无效的路径",
                NSLocalizedFailureReasonErrorKey: "提供的路径格式不正确"
            ]
            
        case .networkError:
            code = NSURLErrorCannotConnectToHost
            userInfo = [
                NSLocalizedDescriptionKey: "网络错误",
                NSLocalizedFailureReasonErrorKey: "无法连接到远程服务器"
            ]
            
        case .authenticationFailed:
            code = NSURLErrorUserAuthenticationRequired
            userInfo = [
                NSLocalizedDescriptionKey: "认证失败",
                NSLocalizedFailureReasonErrorKey: "用户名或密码不正确"
            ]
            
        case .storageNotConfigured:
            code = NSFileReadUnknownError
            userInfo = [
                NSLocalizedDescriptionKey: "存储未配置",
                NSLocalizedFailureReasonErrorKey: "需要先配置存储后端"
            ]
            
        case .directoryCreationFailed(let detail):
            code = NSFileWriteUnknownError
            userInfo = [
                NSLocalizedDescriptionKey: "目录创建失败",
                NSLocalizedFailureReasonErrorKey: detail
            ]
            
        case .fileOperationFailed(let detail):
            code = NSFileWriteUnknownError
            userInfo = [
                NSLocalizedDescriptionKey: "文件操作失败",
                NSLocalizedFailureReasonErrorKey: detail
            ]
        }
        
        return NSError(domain: domain, code: code, userInfo: userInfo)
    }
    
    /// 执行可能抛出 VFSError 的操作，并将错误转换为 NSError
    public static func execute<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch let vfsError as VFSError {
            throw convertToNSError(vfsError)
        } catch {
            // 其他错误直接抛出
            throw error
        }
    }
    
    /// 执行可能抛出 VFSError 的异步操作，并将错误转换为 NSError
    public static func executeAsync<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let vfsError as VFSError {
            throw convertToNSError(vfsError)
        } catch {
            // 其他错误直接抛出
            throw error
        }
    }
}