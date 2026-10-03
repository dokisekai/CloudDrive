//
//  WebDAVStorageClient.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  WebDAV 协议存储客户端
//

import Foundation
import CloudDriveContracts
import CloudDriveSupport

/// WebDAV 存储客户端实现
public class WebDAVStorageClient: StorageClient {
    public var requiresETagForUpdate: Bool { true }
    public let webDAVClient: WebDAVClient
    
    public init(webDAVClient: WebDAVClient) {
        self.webDAVClient = webDAVClient
    }
    
    public convenience init(config: WebDAVStorageConfig) {
        let baseURL = URL(string: config.baseURL) ?? URL(string: "http://localhost")!
        let client = WebDAVClient(baseURL: baseURL, username: config.username, password: config.password)
        self.init(webDAVClient: client)
    }
    
    public func exists(path: String) async throws -> Bool {
        return try await webDAVClient.exists(path: path)
    }
    
    public func listDirectory(path: String) async throws -> [StorageResource] {
        let webDAVResources = try await webDAVClient.listDirectory(path: path)
        return webDAVResources.map { resource in
            StorageResource(
                path: resource.path,
                displayName: resource.displayName,
                isDirectory: resource.isDirectory,
                contentLength: resource.contentLength,
                contentType: resource.contentType,
                creationDate: resource.creationDate,
                lastModified: resource.lastModified,
                etag: resource.etag
            )
        }
    }
    
    public func downloadFile(path: String, to destinationURL: URL, progress: @escaping (Double) -> Void) async throws {
        try await webDAVClient.downloadFile(path: path, to: destinationURL, progress: progress)
    }
    
    public func uploadFile(localURL: URL, to remotePath: String, progress: @escaping (Double) -> Void) async throws {
        try await webDAVClient.uploadFile(localURL: localURL, to: remotePath, progress: progress)
    }

    @discardableResult
    public func uploadFile(localURL: URL, to remotePath: String, expectedETag: String?, progress: @escaping (Double) -> Void) async throws -> String? {
        do {
            return try await webDAVClient.uploadFile(localURL: localURL, to: remotePath, expectedETag: expectedETag, progress: progress)
        } catch WebDAVError.serverError(let code) {
            throw StorageError.serverError(statusCode: code, message: code == 412 ? "Remote revision changed; local edits were not uploaded" : "WebDAV upload failed")
        }
    }

    @discardableResult
    public func uploadFile(localURL: URL, to remotePath: String, mode: StorageWriteMode, progress: @escaping (Double) -> Void) async throws -> String? {
        do {
            return try await webDAVClient.uploadFile(localURL: localURL, to: remotePath, mode: mode, progress: progress)
        } catch WebDAVError.serverError(let code) {
            throw StorageError.serverError(statusCode: code, message: code == 412 ? "Precondition Failed: remote resource changed or already exists" : "WebDAV upload failed")
        }
    }

    @discardableResult
    public func downloadFile(path: String, to destinationURL: URL, expectedETag: String?, progress: @escaping (Double) -> Void) async throws -> String? {
        do {
            return try await webDAVClient.downloadFile(path: path, to: destinationURL, expectedETag: expectedETag, progress: progress)
        } catch WebDAVError.serverError(let code) {
            throw StorageError.serverError(statusCode: code, message: "WebDAV download failed")
        }
    }
    
    public func createDirectory(path: String) async throws {
        try await webDAVClient.createDirectory(path: path)
    }
    
    public func delete(path: String) async throws {
        try await webDAVClient.delete(path: path)
    }

    public func delete(path: String, expectedETag: String?) async throws {
        try await webDAVClient.delete(path: path, expectedETag: expectedETag)
    }
    
    public func move(from sourcePath: String, to destinationPath: String) async throws {
        try await webDAVClient.move(from: sourcePath, to: destinationPath)
    }

    public func move(from sourcePath: String, to destinationPath: String, expectedETag: String?) async throws {
        try await webDAVClient.move(from: sourcePath, to: destinationPath, expectedETag: expectedETag)
    }
    
    public func copy(from sourcePath: String, to destinationPath: String) async throws {
        try await webDAVClient.copy(from: sourcePath, to: destinationPath)
    }

    public func copy(from sourcePath: String, to destinationPath: String, expectedETag: String?) async throws {
        try await webDAVClient.copy(from: sourcePath, to: destinationPath, expectedETag: expectedETag)
    }
    
    public func testConnection() async throws -> Bool {
        return try await webDAVClient.testConnection()
    }
}

/// 保持向后兼容的适配器别名
public typealias WebDAVStorageAdapter = WebDAVStorageClient
