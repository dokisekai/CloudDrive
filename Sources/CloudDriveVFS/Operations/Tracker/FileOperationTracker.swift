//
//  FileOperationTracker.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  文件操作进度与历史跟踪器
//

import Foundation
import Combine

/// 文件操作跟踪器
public class FileOperationTracker: ObservableObject {
    public static let shared = FileOperationTracker()
    
    @Published public var operations: [FileOperationItem] = []
    private let maxOperations = 100
    private let lock = NSLock()
    private var lastProgressUpdateTimes: [String: TimeInterval] = [:]
    private var lastProgressUpdateValues: [String: Double] = [:]
    private let progressThrottleLock = NSLock()
    
    public init() {}
    
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
        
        logOperation(operation, message: "Operation added to queue")
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
                
                self.logOperation(self.operations[index], message: "Status update: \(status.rawValue)")
            }
        }
    }
    
    /// 更新操作进度
    public func updateProgress(id: String, progress: Double) {
        if progress < 1.0 && progress > 0.0 {
            progressThrottleLock.lock()
            let now = Date().timeIntervalSince1970
            let lastTime = lastProgressUpdateTimes[id] ?? 0
            let lastVal = lastProgressUpdateValues[id] ?? 0
            if (now - lastTime < 0.05) && (abs(progress - lastVal) < 0.02) {
                progressThrottleLock.unlock()
                return
            }
            lastProgressUpdateTimes[id] = now
            lastProgressUpdateValues[id] = progress
            progressThrottleLock.unlock()
        } else {
            progressThrottleLock.lock()
            lastProgressUpdateTimes.removeValue(forKey: id)
            lastProgressUpdateValues.removeValue(forKey: id)
            progressThrottleLock.unlock()
        }
        
        DispatchQueue.main.async {
            if let index = self.operations.firstIndex(where: { $0.id == id }) {
                self.operations[index].progress = progress
                if progress > 0 && progress < 1.0 {
                    self.operations[index].status = .inProgress
                }
            }
        }
    }
    
    /// 更新具体阶段
    public func updatePhase(id: String, phase: FileOperationPhase, progress: Double? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let index = self.operations.firstIndex(where: { $0.id == id }) {
                if let p = progress {
                    self.operations[index].progress = p
                }
                switch phase {
                case .queued:
                    self.operations[index].status = .pending
                case .completed:
                    self.operations[index].status = .completed
                    self.operations[index].completedAt = Date()
                case .failed(let err, _):
                    self.operations[index].status = .failed
                    self.operations[index].errorMessage = err
                    self.operations[index].completedAt = Date()
                case .cancelled:
                    self.operations[index].status = .cancelled
                    self.operations[index].completedAt = Date()
                default:
                    self.operations[index].status = .inProgress
                }
                self.logOperation(self.operations[index], message: "Phase: \(phase.description)")
            }
        }
    }
    
    /// 删除操作
    public func removeOperation(id: String) {
        DispatchQueue.main.async {
            self.operations.removeAll { $0.id == id }
        }
    }
    
    /// 清理已完成的旧操作
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
            Logger.shared.info(.fileOps, "⏳ \(logMessage)")
        case .inProgress:
            Logger.shared.info(.fileOps, "🔄 \(logMessage) (\(Int(operation.progress * 100))%)")
        case .completed:
            Logger.shared.success(.fileOps, "✅ \(logMessage)")
        case .failed:
            Logger.shared.error(.fileOps, "❌ \(logMessage) - \(operation.errorMessage ?? "Unknown error")")
        case .cancelled:
            Logger.shared.warning(.fileOps, "⚠️ \(logMessage)")
        }
    }
}
