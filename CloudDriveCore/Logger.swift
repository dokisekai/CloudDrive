//
//  Logger.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  统一日志管理器 - 支持多个独立日志文件和系统日志
//

import Foundation
import os.log

/// 日志管理器 - 统一管理所有日志输出
public class Logger {
    public static let shared = Logger()
    
    private let fileManager = FileManager.default
    private let logDirectory: URL
    private let maxLogFileSize: Int64 = 10 * 1024 * 1024 // 10MB
    private let maxLogFiles = 5
    
    private let logQueue = DispatchQueue(label: "com.clouddrive.logger", qos: .utility)
    
    // 多个日志文件
    private var logFiles: [String: URL] = [:]
    
    // 系统日志对象 - 用于 Xcode 控制台和 Console.app
    private var osLogs: [String: OSLog] = [:]
    
    // 日志类别
    public enum Category: String {
        case system = "system"           // 系统日志
        case fileOps = "file-operations" // 文件操作日志
        case webdav = "webdav"          // WebDAV 日志
        case cache = "cache"            // 缓存日志
        case database = "database"      // 数据库日志
        case sync = "sync"              // 同步日志
    }
    
    // 日志级别
    public enum Level: String {
        case debug = "🔍 DEBUG"
        case info = "ℹ️ INFO"
        case warning = "⚠️ WARNING"
        case error = "❌ ERROR"
        case success = "✅ SUCCESS"
        
        var osLogType: OSLogType {
            switch self {
            case .debug: return .debug
            case .info, .success: return .info
            case .warning: return .default
            case .error: return .error
            }
        }
    }
    
    private init() {
        // 使用 App Group 共享目录
        let sharedContainerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.net.aabg.CloudDrive"
        )
        
        if let sharedContainerURL = sharedContainerURL {
            let appDir = sharedContainerURL.appendingPathComponent(".CloudDrive", isDirectory: true)
            self.logDirectory = appDir.appendingPathComponent("Logs", isDirectory: true)
        } else {
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            let appDir = homeDir.appendingPathComponent(".CloudDrive", isDirectory: true)
            self.logDirectory = appDir.appendingPathComponent("Logs", isDirectory: true)
        }
        
        // 创建日志目录
        try? fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true, attributes: nil)
        
        // 初始化各类日志文件和系统日志
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: Date())
        
        for category in [Category.system, .fileOps, .webdav, .cache, .database, .sync] {
            let logFile = logDirectory.appendingPathComponent("\(category.rawValue)-\(dateString).log")
            logFiles[category.rawValue] = logFile
            
            // 创建对应的系统日志对象
            osLogs[category.rawValue] = OSLog(subsystem: "net.aabg.CloudDrive", category: category.rawValue)
        }
        
        // 清理旧日志
        cleanupOldLogs()
        
        // 写入启动日志
        log(.info, category: .system, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        log(.info, category: .system, "CloudDrive 启动")
        log(.info, category: .system, "日志目录: \(logDirectory.path)")
        log(.info, category: .system, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    }
    
    // MARK: - 公共方法
    
    /// 记录日志
    public func log(_ level: Level, category: Category, _ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let fileName = (file as NSString).lastPathComponent
        let logMessage = "[\(timestamp)] [\(level.rawValue)] \(message) (\(fileName):\(line))"
        
        // 1. 输出到标准输出（Xcode 控制台）
        print("[\(category.rawValue.uppercased())] \(logMessage)")
        
        // 2. 输出到系统日志（Console.app 和 log stream）
        if let osLog = osLogs[category.rawValue] {
            os_log("%{public}@", log: osLog, type: level.osLogType, logMessage)
        }
        
        // 3. 异步写入文件
        logQueue.async { [weak self] in
            self?.writeToFile(logMessage, category: category)
        }
    }
    
    /// 便捷方法
    public func debug(_ category: Category, _ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(.debug, category: category, message, file: file, function: function, line: line)
    }
    
    public func info(_ category: Category, _ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(.info, category: category, message, file: file, function: function, line: line)
    }
    
    public func warning(_ category: Category, _ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(.warning, category: category, message, file: file, function: function, line: line)
    }
    
    public func error(_ category: Category, _ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(.error, category: category, message, file: file, function: function, line: line)
    }
    
    public func success(_ category: Category, _ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(.success, category: category, message, file: file, function: function, line: line)
    }
    
    /// 获取指定类别的日志文件路径
    public func getLogFilePath(for category: Category) -> String? {
        return logFiles[category.rawValue]?.path
    }
    
    /// 获取所有日志文件
    public func getAllLogFiles() -> [URL] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        
        return files.filter { $0.pathExtension == "log" }
            .sorted { url1, url2 in
                let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                return date1 > date2
            }
    }
    
    // MARK: - 私有方法
    
    private func writeToFile(_ message: String, category: Category) {
        guard let logFile = logFiles[category.rawValue] else { return }
        
        let data = (message + "\n").data(using: .utf8) ?? Data()
        
        if fileManager.fileExists(atPath: logFile.path) {
            // 追加到现有文件
            if let fileHandle = try? FileHandle(forWritingTo: logFile) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            }
        } else {
            // 创建新文件
            try? data.write(to: logFile, options: [.atomic])
        }
        
        // 检查文件大小
        if let attributes = try? fileManager.attributesOfItem(atPath: logFile.path),
           let fileSize = attributes[.size] as? Int64,
           fileSize > maxLogFileSize {
            rotateLogFile(category: category)
        }
    }
    
    private func rotateLogFile(category: Category) {
        guard let logFile = logFiles[category.rawValue] else { return }
        
        // 重命名当前日志文件
        let timestamp = Int(Date().timeIntervalSince1970)
        let rotatedFile = logDirectory.appendingPathComponent("\(category.rawValue)-\(timestamp).log")
        try? fileManager.moveItem(at: logFile, to: rotatedFile)
        
        // 创建新的日志文件
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: Date())
        let newLogFile = logDirectory.appendingPathComponent("\(category.rawValue)-\(dateString).log")
        logFiles[category.rawValue] = newLogFile
        
        // 清理旧日志
        cleanupOldLogs()
    }
    
    private func cleanupOldLogs() {
        let logFiles = getAllLogFiles()
        
        // 保留最新的 N 个文件
        if logFiles.count > maxLogFiles {
            for file in logFiles.dropFirst(maxLogFiles) {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}

// MARK: - 便捷全局函数

public func logDebug(_ category: Logger.Category, _ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    Logger.shared.debug(category, message, file: file, function: function, line: line)
}

public func logInfo(_ category: Logger.Category, _ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    Logger.shared.info(category, message, file: file, function: function, line: line)
}

public func logWarning(_ category: Logger.Category, _ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    Logger.shared.warning(category, message, file: file, function: function, line: line)
}

public func logError(_ category: Logger.Category, _ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    Logger.shared.error(category, message, file: file, function: function, line: line)
}

public func logSuccess(_ category: Logger.Category, _ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    Logger.shared.success(category, message, file: file, function: function, line: line)
}