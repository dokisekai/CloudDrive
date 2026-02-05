//
//  FileOperationManager.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyan军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  文件操作状态管理器
//

import Foundation
import Combine

/// 文件操作类型
public enum FileOperationType: String, Codable {
    case create = "创建"
    case delete = "删除"
    case move = "移动"
    case copy = "复制"
    case upload = "上传"
    case download = "下载"
    case modify = "修改"
    case rename = "重命名"
    
    public var icon: String {
        switch self {
        case .create:
            return "doc.badge.plus"
        case .delete:
            return "trash"
        case .move:
            return "arrow.right.arrow.left"
        case .copy:
            return "doc.on.doc"
        case .upload:
            return "arrow.up.circle"
        case .download:
            return "arrow.down.circle"
        case .modify:
            return "pencil"
        case .rename:
            return "pencil.circle"
        }
    }
}

/// 文件操作状态
public enum FileOperationStatus: String, Codable {
    case pending = "等待中"
    case inProgress = "进行中"
    case completed = "已完成"
    case failed = "失败"
    case cancelled = "已取消"
    
    public var icon: String {
        switch self {
        case .pending:
            return "clock"
        case .inProgress:
            return "arrow.triangle.2.circlepath"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .cancelled:
            return "minus.circle"
        }
    }
    
    public var color: String {
        switch self {
        case .pending:
            return "orange"
        case .inProgress:
            return "blue"
        case .completed:
            return "green"
        case .failed:
            return "red"
        case .cancelled:
            return "gray"
        }
    }
}

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

/// 文件操作管理器
public class FileOperationManager: ObservableObject {
    public static let shared = FileOperationManager()
    
    @Published public var operations: [FileOperationItem] = []
    private let maxOperations = 100
    
    private init() {}
    
    /// 添加操作
    public func addOperation(type: FileOperationType, fileName: String, filePath: String) -> String {
        let operation = FileOperationItem(
            type: type,
            fileName: fileName,
            filePath: filePath,
            status: .pending
        )
        
        DispatchQueue.main.async {
            self.operations.append(operation)
            self.cleanupOldOperations()
        }
        
        logOperation(operation, message: "操作已添加到队列")
        
        return operation.id
    }
    
    /// 更新操作状态
    public func updateOperation(id: String, status: FileOperationStatus, progress: Double = 0.0, errorMessage: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let index = self.operations.firstIndex(where: { $0.id == id }) {
                self.operations[index].status = status
                self.operations[index].progress = progress
                
                if status == .completed || status == .failed || status == .cancelled {
                    self.operations[index].completedAt = Date()
                    if let error = errorMessage {
                        self.operations[index].errorMessage = error
                    }
                }
                
                self.logOperation(self.operations[index], message: "状态更新: \(status.rawValue)")
            }
        }
    }
    
    /// 更新操作进度
    public func updateProgress(id: String, progress: Double) {
        DispatchQueue.main.async {
            if let index = self.operations.firstIndex(where: { $0.id == id }) {
                self.operations[index].progress = progress
                if progress > 0 && progress < 1.0 {
                    self.operations[index].status = .inProgress
                }
            }
        }
    }
    
    /// 删除操作
    public func removeOperation(id: String) {
        DispatchQueue.main.async {
            self.operations.removeAll { $0.id == id }
        }
    }
    
    /// 清理旧操作
    private func cleanupOldOperations() {
        let completedOperations = operations.filter { $0.status == .completed }
        if completedOperations.count > maxOperations {
            let toRemove = completedOperations.prefix(completedOperations.count - maxOperations)
            operations.removeAll { op in
                toRemove.contains { $0.id == op.id }
            }
        }
    }
    
    /// 清除所有操作
    public func clearAllOperations() {
        DispatchQueue.main.async {
            self.operations.removeAll()
        }
    }
    
    /// 获取进行中的操作
    public var inProgressOperations: [FileOperationItem] {
        operations.filter { $0.status == .inProgress }
    }
    
    /// 获取等待中的操作
    public var pendingOperations: [FileOperationItem] {
        operations.filter { $0.status == .pending }
    }
    
    /// 获取失败的操作
    public var failedOperations: [FileOperationItem] {
        operations.filter { $0.status == .failed }
    }
    
    private func logOperation(_ operation: FileOperationItem, message: String) {
        let logMessage = "[\(operation.type.rawValue)] \(operation.fileName) - \(message)"
        
        switch operation.status {
        case .pending:
            logInfo(.fileOps, "⏳ \(logMessage)")
        case .inProgress:
            logInfo(.fileOps, "🔄 \(logMessage) (\(Int(operation.progress * 100))%)")
        case .completed:
            logSuccess(.fileOps, "✅ \(logMessage)")
        case .failed:
            logError(.fileOps, "❌ \(logMessage) - \(operation.errorMessage ?? "未知错误")")
        case .cancelled:
            logWarning(.fileOps, "⚠️ \(logMessage)")
        }
    }
}
