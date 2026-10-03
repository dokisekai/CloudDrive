//
//  FileOperationItem.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  文件操作项模型
//

import Foundation

/// 文件操作项
public struct FileOperationItem: Identifiable, Codable {
    public let id: String
    public let type: FileOperationType
    public let fileName: String
    public let filePath: String
    public var status: FileOperationStatus
    public let createdAt: Date
    public var completedAt: Date?
    public var errorMessage: String?
    public var progress: Double
    
    public init(
        id: String = UUID().uuidString,
        type: FileOperationType,
        fileName: String,
        filePath: String,
        status: FileOperationStatus = .pending,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        errorMessage: String? = nil,
        progress: Double = 0.0
    ) {
        self.id = id
        self.type = type
        self.fileName = fileName
        self.filePath = filePath
        self.status = status
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
        self.progress = progress
    }
}
