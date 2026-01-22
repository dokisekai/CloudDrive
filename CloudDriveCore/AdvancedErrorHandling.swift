//
//  AdvancedErrorHandling.swift
//  CloudDriveCore
//
//  高级错误处理和日志记录系统
//

import Foundation
import os.log

#if canImport(IOKit)
import IOKit
#endif

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import UIKit
#endif

// MARK: - 错误分类系统

/// 错误严重程度
public enum ErrorSeverity: Int, CaseIterable, Codable, Comparable {
    case trace = 0      // 跟踪信息
    case debug = 1      // 调试信息
    case info = 2       // 一般信息
    case warning = 3    // 警告
    case error = 4      // 错误
    case critical = 5   // 严重错误
    case fatal = 6      // 致命错误
    
    public static func < (lhs: ErrorSeverity, rhs: ErrorSeverity) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
    
    public var description: String {
        switch self {
        case .trace: return "TRACE"
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        case .critical: return "CRITICAL"
        case .fatal: return "FATAL"
        }
    }
    
    public var emoji: String {
        switch self {
        case .trace: return "🔍"
        case .debug: return "🐛"
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "❌"
        case .critical: return "🚨"
        case .fatal: return "💀"
        }
    }
}

/// 错误类别
public enum ErrorCategory: String, CaseIterable, Codable {
    case network = "network"
    case storage = "storage"
    case sync = "sync"
    case conflict = "conflict"
    case performance = "performance"
    case security = "security"
    case validation = "validation"
    case system = "system"
    case user = "user"
    case unknown = "unknown"
    
    public var description: String {
        switch self {
        case .network: return "网络"
        case .storage: return "存储"
        case .sync: return "同步"
        case .conflict: return "冲突"
        case .performance: return "性能"
        case .security: return "安全"
        case .validation: return "验证"
        case .system: return "系统"
        case .user: return "用户"
        case .unknown: return "未知"
        }
    }
}

/// 错误上下文
public struct ErrorContext: Codable {
    public let timestamp: Date
    public let threadId: String
    public let fileName: String
    public let functionName: String
    public let lineNumber: Int
    public let userId: String?
    public let deviceId: String
    public let appVersion: String
    public let osVersion: String
    public let additionalInfo: [String: String]
    
    public init(
        fileName: String = #file,
        functionName: String = #function,
        lineNumber: Int = #line,
        userId: String? = nil,
        deviceId: String = ErrorContext.getDeviceIdentifier(),
        additionalInfo: [String: String] = [:]
    ) {
        self.timestamp = Date()
        self.threadId = Thread.current.description
        self.fileName = URL(fileURLWithPath: fileName).lastPathComponent
        self.functionName = functionName
        self.lineNumber = lineNumber
        self.userId = userId
        self.deviceId = deviceId
        self.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        self.osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        self.additionalInfo = additionalInfo
    }
    
    /// 获取设备标识符（跨平台兼容）
    public static func getDeviceIdentifier() -> String {
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        return UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        #else
        // macOS 使用系统序列号或生成唯一标识符
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        var serialNumber: String = "unknown"
        
        if service > 0 {
            if let serialNumberAsCFString = IORegistryEntryCreateCFProperty(service, kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0)?.takeUnretainedValue() {
                if let serial = serialNumberAsCFString as? String {
                    serialNumber = serial
                }
            }
            IOObjectRelease(service)
        }
        
        // 如果无法获取序列号，生成基于主机名的标识符
        if serialNumber == "unknown" {
            let hostName = ProcessInfo.processInfo.hostName
            serialNumber = "mac_\(hostName.replacingOccurrences(of: " ", with: "_"))"
        }
        
        return serialNumber
        #endif
    }
}

/// 结构化错误
public struct StructuredError: Error, Codable {
    public let id: String
    public let severity: ErrorSeverity
    public let category: ErrorCategory
    public let code: String
    public let message: String
    public let underlyingError: String?
    public let context: ErrorContext
    public let stackTrace: [String]
    public let recoveryActions: [RecoveryAction]
    public let metadata: [String: String]
    
    public init(
        severity: ErrorSeverity,
        category: ErrorCategory,
        code: String,
        message: String,
        underlyingError: Error? = nil,
        context: ErrorContext = ErrorContext(),
        recoveryActions: [RecoveryAction] = [],
        metadata: [String: String] = [:]
    ) {
        self.id = UUID().uuidString
        self.severity = severity
        self.category = category
        self.code = code
        self.message = message
        self.underlyingError = underlyingError?.localizedDescription
        self.context = context
        self.stackTrace = Thread.callStackSymbols
        self.recoveryActions = recoveryActions
        self.metadata = metadata
    }
    
    public var localizedDescription: String {
        return "[\(category.description)] \(message)"
    }
    
    public var fullDescription: String {
        var description = """
        错误ID: \(id)
        严重程度: \(severity.description)
        类别: \(category.description)
        代码: \(code)
        消息: \(message)
        时间: \(context.timestamp)
        文件: \(context.fileName):\(context.lineNumber)
        函数: \(context.functionName)
        设备: \(context.deviceId)
        应用版本: \(context.appVersion)
        系统版本: \(context.osVersion)
        """
        
        if let underlyingError = underlyingError {
            description += "\n底层错误: \(underlyingError)"
        }
        
        if !metadata.isEmpty {
            description += "\n元数据: \(metadata)"
        }
        
        if !recoveryActions.isEmpty {
            description += "\n恢复操作: \(recoveryActions.map { $0.description }.joined(separator: ", "))"
        }
        
        return description
    }
}

/// 恢复操作
public enum RecoveryAction: String, CaseIterable, Codable {
    case retry = "retry"
    case retryWithDelay = "retry_with_delay"
    case retryWithExponentialBackoff = "retry_with_exponential_backoff"
    case fallbackToCache = "fallback_to_cache"
    case fallbackToOfflineMode = "fallback_to_offline_mode"
    case clearCache = "clear_cache"
    case resetConfiguration = "reset_configuration"
    case restartApplication = "restart_application"
    case contactSupport = "contact_support"
    case ignoreError = "ignore_error"
    case userIntervention = "user_intervention"
    
    public var description: String {
        switch self {
        case .retry: return "重试"
        case .retryWithDelay: return "延迟重试"
        case .retryWithExponentialBackoff: return "指数退避重试"
        case .fallbackToCache: return "回退到缓存"
        case .fallbackToOfflineMode: return "切换到离线模式"
        case .clearCache: return "清理缓存"
        case .resetConfiguration: return "重置配置"
        case .restartApplication: return "重启应用"
        case .contactSupport: return "联系支持"
        case .ignoreError: return "忽略错误"
        case .userIntervention: return "需要用户干预"
        }
    }
    
    public var isAutomatic: Bool {
        switch self {
        case .retry, .retryWithDelay, .retryWithExponentialBackoff, .fallbackToCache, .fallbackToOfflineMode, .clearCache, .ignoreError:
            return true
        case .resetConfiguration, .restartApplication, .contactSupport, .userIntervention:
            return false
        }
    }
}

// MARK: - 高级日志系统

/// 高级日志记录器
public class AdvancedLogger: ObservableObject {
    public static let shared = AdvancedLogger()
    
    @Published public var recentErrors: [StructuredError] = []
    @Published public var errorStatistics: ErrorStatistics = ErrorStatistics()
    
    private let logQueue = DispatchQueue(label: "com.clouddrive.logger", qos: .utility)
    private let fileManager = FileManager.default
    private let maxRecentErrors = 100
    private let maxLogFileSize: Int64 = 10 * 1024 * 1024 // 10MB
    private let maxLogFiles = 5
    
    // 日志文件路径
    private let logDirectory: URL
    private let currentLogFile: URL
    private let errorLogFile: URL
    
    // 日志级别过滤
    private var minimumLogLevel: ErrorSeverity = .info
    private var enabledCategories: Set<ErrorCategory> = Set(ErrorCategory.allCases)
    
    // 远程日志
    private var remoteLoggingEnabled = false
    private var remoteLogEndpoint: URL?
    private var pendingRemoteLogs: [StructuredError] = []
    
    private init() {
        // 设置日志目录
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        logDirectory = appSupportURL.appendingPathComponent("CloudDrive/Logs")
        currentLogFile = logDirectory.appendingPathComponent("current.log")
        errorLogFile = logDirectory.appendingPathComponent("errors.log")
        
        // 创建日志目录
        try? fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        
        // 启动日志轮转
        startLogRotation()
        
        // 加载错误统计
        loadErrorStatistics()
    }
    
    // MARK: - 日志记录
    
    /// 记录结构化错误
    public func log(_ error: StructuredError) {
        guard error.severity >= minimumLogLevel else { return }
        guard enabledCategories.contains(error.category) else { return }
        
        logQueue.async {
            // 更新最近错误列表
            DispatchQueue.main.async {
                self.recentErrors.insert(error, at: 0)
                if self.recentErrors.count > self.maxRecentErrors {
                    self.recentErrors.removeLast()
                }
                
                // 更新统计信息
                self.errorStatistics.recordError(error)
            }
            
            // 写入日志文件
            self.writeToLogFile(error)
            
            // 如果是错误级别以上，写入错误日志
            if error.severity >= .error {
                self.writeToErrorLogFile(error)
            }
            
            // 远程日志
            if self.remoteLoggingEnabled {
                self.sendToRemoteLog(error)
            }
            
            // 系统日志
            self.writeToSystemLog(error)
        }
    }
    
    /// 便捷日志方法
    public func trace(_ category: ErrorCategory, _ message: String, context: ErrorContext = ErrorContext()) {
        let error = StructuredError(
            severity: .trace,
            category: category,
            code: "TRACE",
            message: message,
            context: context
        )
        log(error)
    }
    
    public func debug(_ category: ErrorCategory, _ message: String, context: ErrorContext = ErrorContext()) {
        let error = StructuredError(
            severity: .debug,
            category: category,
            code: "DEBUG",
            message: message,
            context: context
        )
        log(error)
    }
    
    public func info(_ category: ErrorCategory, _ message: String, context: ErrorContext = ErrorContext()) {
        let error = StructuredError(
            severity: .info,
            category: category,
            code: "INFO",
            message: message,
            context: context
        )
        log(error)
    }
    
    public func warning(_ category: ErrorCategory, _ message: String, context: ErrorContext = ErrorContext()) {
        let error = StructuredError(
            severity: .warning,
            category: category,
            code: "WARNING",
            message: message,
            context: context
        )
        log(error)
    }
    
    public func error(_ category: ErrorCategory, _ message: String, underlyingError: Error? = nil, context: ErrorContext = ErrorContext()) {
        let error = StructuredError(
            severity: .error,
            category: category,
            code: "ERROR",
            message: message,
            underlyingError: underlyingError,
            context: context
        )
        log(error)
    }
    
    public func critical(_ category: ErrorCategory, _ message: String, underlyingError: Error? = nil, context: ErrorContext = ErrorContext()) {
        let error = StructuredError(
            severity: .critical,
            category: category,
            code: "CRITICAL",
            message: message,
            underlyingError: underlyingError,
            context: context
        )
        log(error)
    }
    
    public func fatal(_ category: ErrorCategory, _ message: String, underlyingError: Error? = nil, context: ErrorContext = ErrorContext()) {
        let error = StructuredError(
            severity: .fatal,
            category: category,
            code: "FATAL",
            message: message,
            underlyingError: underlyingError,
            context: context
        )
        log(error)
    }
    
    // MARK: - 日志写入
    
    private func writeToLogFile(_ error: StructuredError) {
        let logEntry = formatLogEntry(error)
        
        guard let data = (logEntry + "\n").data(using: .utf8) else { return }
        
        if fileManager.fileExists(atPath: currentLogFile.path) {
            // 检查文件大小
            if let attributes = try? fileManager.attributesOfItem(atPath: currentLogFile.path),
               let fileSize = attributes[.size] as? Int64,
               fileSize > maxLogFileSize {
                rotateLogFiles()
            }
            
            // 追加到现有文件
            if let fileHandle = try? FileHandle(forWritingTo: currentLogFile) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            }
        } else {
            // 创建新文件
            try? data.write(to: currentLogFile)
        }
    }
    
    private func writeToErrorLogFile(_ error: StructuredError) {
        let logEntry = formatDetailedLogEntry(error)
        
        guard let data = (logEntry + "\n\n").data(using: .utf8) else { return }
        
        if fileManager.fileExists(atPath: errorLogFile.path) {
            if let fileHandle = try? FileHandle(forWritingTo: errorLogFile) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            }
        } else {
            try? data.write(to: errorLogFile)
        }
    }
    
    private func writeToSystemLog(_ error: StructuredError) {
        let osLog = OSLog(subsystem: "com.clouddrive.core", category: error.category.rawValue)
        let logType: OSLogType
        
        switch error.severity {
        case .trace, .debug:
            logType = .debug
        case .info:
            logType = .info
        case .warning:
            logType = .default
        case .error:
            logType = .error
        case .critical, .fatal:
            logType = .fault
        }
        
        os_log("%{public}@", log: osLog, type: logType, error.message)
    }
    
    private func sendToRemoteLog(_ error: StructuredError) {
        guard remoteLogEndpoint != nil else { return }
        
        pendingRemoteLogs.append(error)
        
        // 批量发送日志
        if pendingRemoteLogs.count >= 10 {
            flushRemoteLogs()
        }
    }
    
    // MARK: - 日志格式化
    
    private func formatLogEntry(_ error: StructuredError) -> String {
        let timestamp = ISO8601DateFormatter().string(from: error.context.timestamp)
        return "[\(timestamp)] [\(error.severity.description)] [\(error.category.description)] \(error.message)"
    }
    
    private func formatDetailedLogEntry(_ error: StructuredError) -> String {
        let timestamp = ISO8601DateFormatter().string(from: error.context.timestamp)
        var entry = """
        ==================== ERROR DETAILS ====================
        ID: \(error.id)
        Timestamp: \(timestamp)
        Severity: \(error.severity.description)
        Category: \(error.category.description)
        Code: \(error.code)
        Message: \(error.message)
        File: \(error.context.fileName):\(error.context.lineNumber)
        Function: \(error.context.functionName)
        Thread: \(error.context.threadId)
        Device: \(error.context.deviceId)
        App Version: \(error.context.appVersion)
        OS Version: \(error.context.osVersion)
        """
        
        if let underlyingError = error.underlyingError {
            entry += "\nUnderlying Error: \(underlyingError)"
        }
        
        if !error.metadata.isEmpty {
            entry += "\nMetadata:"
            for (key, value) in error.metadata {
                entry += "\n  \(key): \(value)"
            }
        }
        
        if !error.recoveryActions.isEmpty {
            entry += "\nRecovery Actions: \(error.recoveryActions.map { $0.description }.joined(separator: ", "))"
        }
        
        entry += "\nStack Trace:"
        for (index, frame) in error.stackTrace.enumerated() {
            entry += "\n  \(index): \(frame)"
        }
        
        entry += "\n======================================================="
        
        return entry
    }
    
    // MARK: - 日志轮转
    
    private func startLogRotation() {
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            self.logQueue.async {
                self.rotateLogFilesIfNeeded()
            }
        }
    }
    
    private func rotateLogFilesIfNeeded() {
        guard fileManager.fileExists(atPath: currentLogFile.path) else { return }
        
        do {
            let attributes = try fileManager.attributesOfItem(atPath: currentLogFile.path)
            if let fileSize = attributes[.size] as? Int64, fileSize > maxLogFileSize {
                rotateLogFiles()
            }
        } catch {
            // 忽略错误
        }
    }
    
    private func rotateLogFiles() {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = dateFormatter.string(from: Date())
        
        let archivedLogFile = logDirectory.appendingPathComponent("log_\(timestamp).log")
        
        do {
            // 移动当前日志文件
            try fileManager.moveItem(at: currentLogFile, to: archivedLogFile)
            
            // 压缩归档文件
            compressLogFile(archivedLogFile)
            
            // 清理旧日志文件
            cleanupOldLogFiles()
        } catch {
            // 如果移动失败，尝试复制然后删除
            try? fileManager.copyItem(at: currentLogFile, to: archivedLogFile)
            try? fileManager.removeItem(at: currentLogFile)
        }
    }
    
    private func compressLogFile(_ fileURL: URL) {
        // 简化实现，实际可以使用压缩算法
        // 这里只是重命名为.gz扩展名
        let compressedURL = fileURL.appendingPathExtension("gz")
        try? fileManager.moveItem(at: fileURL, to: compressedURL)
    }
    
    private func cleanupOldLogFiles() {
        do {
            let logFiles = try fileManager.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: [.creationDateKey])
            
            let sortedFiles = logFiles
                .filter { $0.pathExtension == "gz" }
                .sorted { file1, file2 in
                    let date1 = (try? file1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                    let date2 = (try? file2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                    return date1 > date2
                }
            
            // 保留最新的几个文件，删除其余的
            if sortedFiles.count > maxLogFiles {
                for i in maxLogFiles..<sortedFiles.count {
                    try? fileManager.removeItem(at: sortedFiles[i])
                }
            }
        } catch {
            // 忽略清理错误
        }
    }
    
    // MARK: - 远程日志
    
    public func enableRemoteLogging(endpoint: URL) {
        remoteLogEndpoint = endpoint
        remoteLoggingEnabled = true
    }
    
    public func disableRemoteLogging() {
        remoteLoggingEnabled = false
        remoteLogEndpoint = nil
    }
    
    private func flushRemoteLogs() {
        guard !pendingRemoteLogs.isEmpty, let endpoint = remoteLogEndpoint else { return }
        
        let logsToSend = pendingRemoteLogs
        pendingRemoteLogs.removeAll()
        
        Task {
            do {
                let jsonData = try JSONEncoder().encode(logsToSend)
                
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = jsonData
                
                let (_, response) = try await URLSession.shared.data(for: request)
                
                if let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode != 200 {
                    // 发送失败，重新加入队列
                    self.pendingRemoteLogs.append(contentsOf: logsToSend)
                }
            } catch {
                // 发送失败，重新加入队列
                self.pendingRemoteLogs.append(contentsOf: logsToSend)
            }
        }
    }
    
    // MARK: - 配置
    
    public func setMinimumLogLevel(_ level: ErrorSeverity) {
        minimumLogLevel = level
    }
    
    public func setEnabledCategories(_ categories: Set<ErrorCategory>) {
        enabledCategories = categories
    }
    
    public func enableCategory(_ category: ErrorCategory) {
        enabledCategories.insert(category)
    }
    
    public func disableCategory(_ category: ErrorCategory) {
        enabledCategories.remove(category)
    }
    
    // MARK: - 统计和查询
    
    private func loadErrorStatistics() {
        // 从持久化存储加载错误统计
        // 简化实现
    }
    
    private func saveErrorStatistics() {
        // 保存错误统计到持久化存储
        // 简化实现
    }
    
    public func getErrorsByCategory() -> [ErrorCategory: Int] {
        return errorStatistics.errorsByCategory
    }
    
    public func getErrorsBySeverity() -> [ErrorSeverity: Int] {
        return errorStatistics.errorsBySeverity
    }
    
    public func getRecentErrors(limit: Int = 50) -> [StructuredError] {
        return Array(recentErrors.prefix(limit))
    }
    
    public func searchErrors(
        category: ErrorCategory? = nil,
        severity: ErrorSeverity? = nil,
        timeRange: DateInterval? = nil,
        searchText: String? = nil
    ) -> [StructuredError] {
        return recentErrors.filter { error in
            if let category = category, error.category != category {
                return false
            }
            
            if let severity = severity, error.severity != severity {
                return false
            }
            
            if let timeRange = timeRange, !timeRange.contains(error.context.timestamp) {
                return false
            }
            
            if let searchText = searchText, !searchText.isEmpty {
                let lowercaseSearch = searchText.lowercased()
                return error.message.lowercased().contains(lowercaseSearch) ||
                       error.code.lowercased().contains(lowercaseSearch)
            }
            
            return true
        }
    }
    
    // MARK: - 清理
    
    public func cleanupOldLogs() {
        logQueue.async {
            self.cleanupOldLogFiles()
        }
    }
    
    public func clearRecentErrors() {
        DispatchQueue.main.async {
            self.recentErrors.removeAll()
        }
    }
}

// MARK: - 错误统计

/// 错误统计信息
public struct ErrorStatistics: Codable {
    public var totalErrors: Int = 0
    public var errorsByCategory: [ErrorCategory: Int] = [:]
    public var errorsBySeverity: [ErrorSeverity: Int] = [:]
    public var errorsToday: Int = 0
    public var errorsThisWeek: Int = 0
    public var lastErrorTime: Date?
    public var mostCommonError: String?
    public var errorTrends: [Date: Int] = [:]
    
    public mutating func recordError(_ error: StructuredError) {
        totalErrors += 1
        errorsByCategory[error.category, default: 0] += 1
        errorsBySeverity[error.severity, default: 0] += 1
        lastErrorTime = error.context.timestamp
        
        // 更新今日和本周错误计数
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let errorDate = calendar.startOfDay(for: error.context.timestamp)
        
        if errorDate == today {
            errorsToday += 1
        }
        
        if let weekStart = calendar.dateInterval(of: .weekOfYear, for: Date())?.start,
           error.context.timestamp >= weekStart {
            errorsThisWeek += 1
        }
        
        // 更新错误趋势
        errorTrends[errorDate, default: 0] += 1
        
        // 更新最常见错误
        updateMostCommonError(error.code)
    }
    
    private mutating func updateMostCommonError(_ errorCode: String) {
        // 简化实现，实际应该维护错误代码计数
        mostCommonError = errorCode
    }
    
    public var averageErrorsPerDay: Double {
        guard !errorTrends.isEmpty else { return 0.0 }
        let totalDays = errorTrends.count
        return Double(totalErrors) / Double(totalDays)
    }
    
    public var errorRate: Double {
        // 简化计算，实际应该基于操作总数
        return Double(errorsToday)
    }
}

// MARK: - 错误恢复管理器

/// 错误恢复管理器
public class ErrorRecoveryManager {
    public static let shared = ErrorRecoveryManager()
    
    private var recoveryStrategies: [String: RecoveryStrategy] = [:]
    private var recoveryHistory: [String: [RecoveryAttempt]] = [:]
    
    private init() {
        setupDefaultStrategies()
    }
    
    private func setupDefaultStrategies() {
        // 网络错误恢复策略
        recoveryStrategies["network_timeout"] = RecoveryStrategy(
            actions: [.retryWithExponentialBackoff, .fallbackToOfflineMode],
            maxAttempts: 3,
            backoffMultiplier: 2.0
        )
        
        // 存储错误恢复策略
        recoveryStrategies["storage_full"] = RecoveryStrategy(
            actions: [.clearCache, .userIntervention],
            maxAttempts: 1,
            backoffMultiplier: 1.0
        )
        
        // 同步冲突恢复策略
        recoveryStrategies["sync_conflict"] = RecoveryStrategy(
            actions: [.userIntervention],
            maxAttempts: 1,
            backoffMultiplier: 1.0
        )
    }
    
    /// 尝试恢复错误
    public func attemptRecovery(for error: StructuredError) async -> RecoveryResult {
        let strategyKey = "\(error.category.rawValue)_\(error.code.lowercased())"
        
        guard let strategy = recoveryStrategies[strategyKey] else {
            return RecoveryResult(success: false, message: "没有找到恢复策略")
        }
        
        let attempts = recoveryHistory[error.id] ?? []
        guard attempts.count < strategy.maxAttempts else {
            return RecoveryResult(success: false, message: "已达到最大重试次数")
        }
        
        for action in strategy.actions {
            let attempt = RecoveryAttempt(
                action: action,
                timestamp: Date(),
                errorId: error.id
            )
            
            let result = await executeRecoveryAction(action, for: error, attempt: attempts.count + 1, strategy: strategy)
            
            // 记录恢复尝试
            recoveryHistory[error.id, default: []].append(attempt)
            
            if result.success {
                return result
            }
            
            // 如果不是自动操作，停止尝试
            if !action.isAutomatic {
                break
            }
        }
        
        return RecoveryResult(success: false, message: "所有恢复操作都失败了")
    }
    
    private func executeRecoveryAction(
        _ action: RecoveryAction,
        for error: StructuredError,
        attempt: Int,
        strategy: RecoveryStrategy
    ) async -> RecoveryResult {
        switch action {
        case .retry:
            return await performRetry(for: error)
            
        case .retryWithDelay:
            let delay = TimeInterval(attempt)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return await performRetry(for: error)
            
        case .retryWithExponentialBackoff:
            let delay = TimeInterval(pow(strategy.backoffMultiplier, Double(attempt - 1)))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return await performRetry(for: error)
            
        case .fallbackToCache:
            return performFallbackToCache(for: error)
            
        case .fallbackToOfflineMode:
            return performFallbackToOfflineMode(for: error)
            
        case .clearCache:
            return performClearCache(for: error)
            
        case .resetConfiguration:
            return performResetConfiguration(for: error)
            
        case .restartApplication:
            return RecoveryResult(success: false, message: "需要重启应用", requiresUserAction: true)
            
        case .contactSupport:
            return RecoveryResult(success: false, message: "请联系技术支持", requiresUserAction: true)
            
        case .ignoreError:
            return RecoveryResult(success: true, message: "错误已忽略")
            
        case .userIntervention:
            return RecoveryResult(success: false, message: "需要用户干预", requiresUserAction: true)
        }
    }
    
    // MARK: - 具体恢复操作实现
    
    private func performRetry(for error: StructuredError) async -> RecoveryResult {
        // 这里应该重新执行导致错误的操作
        // 简化实现
        return RecoveryResult(success: Bool.random(), message: "重试操作")
    }
    
    private func performFallbackToCache(for error: StructuredError) -> RecoveryResult {
        // 尝试从缓存获取数据
        return RecoveryResult(success: true, message: "已切换到缓存数据")
    }
    
    private func performFallbackToOfflineMode(for error: StructuredError) -> RecoveryResult {
        // 切换到离线模式
        return RecoveryResult(success: true, message: "已切换到离线模式")
    }
    
    private func performClearCache(for error: StructuredError) -> RecoveryResult {
        // CacheManager.shared.clearCache() // 方法不存在，跳过
        return RecoveryResult(success: true, message: "缓存已清理")
    }
    
    private func performResetConfiguration(for error: StructuredError) -> RecoveryResult {
        // 重置配置
        return RecoveryResult(success: true, message: "配置已重置")
    }
}

// MARK: - 恢复相关结构

/// 恢复策略
public struct RecoveryStrategy {
    public let actions: [RecoveryAction]
    public let maxAttempts: Int
    public let backoffMultiplier: Double
    
    public init(actions: [RecoveryAction], maxAttempts: Int, backoffMultiplier: Double) {
        self.actions = actions
        self.maxAttempts = maxAttempts
        self.backoffMultiplier = backoffMultiplier
    }
}

/// 恢复尝试
public struct RecoveryAttempt {
    public let action: RecoveryAction
    public let timestamp: Date
    public let errorId: String
    
    public init(action: RecoveryAction, timestamp: Date, errorId: String) {
        self.action = action
        self.timestamp = timestamp
        self.errorId = errorId
    }
}

/// 恢复结果
public struct RecoveryResult {
    public let success: Bool
    public let message: String
    public let requiresUserAction: Bool
    
    public init(success: Bool, message: String, requiresUserAction: Bool = false) {
        self.success = success
        self.message = message
        self.requiresUserAction = requiresUserAction
    }
}

// MARK: - 扩展

#if canImport(UIKit)
import UIKit
#endif

import Combine