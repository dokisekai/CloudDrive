//
//  RecycleBinItem.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  回收站元数据模型
//

import Foundation

public struct RecycleBinItem: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let vaultId: String
    public let fileId: String
    public let name: String
    public let originalParentId: String
    public let originalRemotePath: String
    public let isDirectory: Bool
    public let size: Int64
    public let deletedAt: Date
    public let localBackupPath: String?
    
    public init(
        id: String = UUID().uuidString,
        vaultId: String,
        fileId: String,
        name: String,
        originalParentId: String,
        originalRemotePath: String,
        isDirectory: Bool,
        size: Int64,
        deletedAt: Date = Date(),
        localBackupPath: String? = nil
    ) {
        self.id = id
        self.vaultId = vaultId
        self.fileId = fileId
        self.name = name
        self.originalParentId = originalParentId
        self.originalRemotePath = originalRemotePath
        self.isDirectory = isDirectory
        self.size = size
        self.deletedAt = deletedAt
        self.localBackupPath = localBackupPath
    }
}
