//
//  LogWindowController.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  日志窗口控制器 - 支持多窗口
//

import SwiftUI
import AppKit
import CloudDriveCore

class LogWindowController: ObservableObject {
    static let shared = LogWindowController()
    
    @Published var openWindows: [LogWindowInfo] = []
    private var windowDelegates: [String: LogWindowDelegate] = [:]
    
    private init() {
        NotificationCenter.default.addObserver(
            forName: LocalizationManager.languageDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateWindowTitles()
        }
    }
    
    private func updateWindowTitles() {
        for windowInfo in openWindows {
            let newTitle = "\(windowInfo.category.displayName) \(L("tab_logs"))"
            if let window = NSApp.windows.first(where: { $0.frameAutosaveName == "LogWindow-\(windowInfo.category.rawValue)" || $0.title == windowInfo.title }) {
                window.title = newTitle
            }
        }
    }
    
    func openLogWindow(for category: Logger.Category) {
        let windowInfo = LogWindowInfo(
            id: UUID().uuidString,
            category: category,
            title: "\(category.displayName) \(L("tab_logs"))"
        )
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = windowInfo.title
        window.center()
        window.setFrameAutosaveName("LogWindow-\(category.rawValue)")
        
        let logView = LogWindowView(category: category, windowInfo: windowInfo)
        let hostingController = NSHostingController(rootView: logView)
        
        window.contentViewController = hostingController
        
        window.makeKeyAndOrderFront(nil)
        
        DispatchQueue.main.async {
            self.openWindows.append(windowInfo)
        }
        
        let delegate = LogWindowDelegate(windowInfo: windowInfo, controller: self)
        windowDelegates[windowInfo.id] = delegate
        window.delegate = delegate
    }
    
    func closeWindow(_ windowInfo: LogWindowInfo) {
        openWindows.removeAll { $0.id == windowInfo.id }
        windowDelegates.removeValue(forKey: windowInfo.id)
    }
}

class LogWindowDelegate: NSObject, NSWindowDelegate {
    let windowInfo: LogWindowInfo
    weak var controller: LogWindowController?
    
    init(windowInfo: LogWindowInfo, controller: LogWindowController) {
        self.windowInfo = windowInfo
        self.controller = controller
        super.init()
    }
    
    func windowWillClose(_ notification: Notification) {
        controller?.closeWindow(windowInfo)
    }
}

struct LogWindowInfo: Identifiable {
    let id: String
    let category: Logger.Category
    let title: String
}

struct LogWindowView: View {
    let category: Logger.Category
    let windowInfo: LogWindowInfo
    @ObservedObject private var localization = LocalizationManager.shared
    
    @State private var selectedLevel: LogLevelFilter = .all
    @State private var logEntries: [LogEntry] = []
    @State private var searchText = ""
    @State private var isRefreshing = false
    @State private var autoScroll = true
    @State private var showExportSheet = false
    @State private var filteredLogEntries: [LogEntry] = []
    @State private var refreshTimer: Timer?
    @State private var showOperations = false
    @ObservedObject private var operationManager = FileOperationManager.shared
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(category.displayName) \(L("tab_logs"))")
                    .font(.headline)
                    .fontWeight(.bold)
                
                Spacer()
                
                Button(action: { showOperations.toggle() }) {
                    Image(systemName: "list.bullet.rectangle")
                }
                .help(L("log_file_ops_panel_title"))
                .background(showOperations ? Color.accentColor : Color.clear)
                .cornerRadius(6)
                
                Picker(L("log_level_filter"), selection: $selectedLevel) {
                    ForEach(LogLevelFilter.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)
                
                Button(action: refreshLogs) {
                    if isRefreshing {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)
                .help(L("refresh"))
                
                Button(action: clearLogs) {
                    Image(systemName: "trash")
                }
                .help(L("delete"))
                
                Toggle(isOn: $autoScroll) {
                    Image(systemName: "arrow.down")
                }
                .help(L("log_auto_scroll"))
                
                Button(action: { showExportSheet = true }) {
                    Image(systemName: "square.and.arrow.up")
                }
                .help(L("log_export"))
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            if showOperations {
                FileOperationsPanel()
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.3), value: showOperations)
                
                Divider()
            }
            
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                
                TextField(L("log_search_placeholder"), text: $searchText)
                    .textFieldStyle(.plain)
                
                Spacer()
                
                Text(L("log_records_count", filteredLogEntries.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            if filteredLogEntries.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 80))
                        .foregroundColor(.secondary)
                    
                    Text(L("log_not_found"))
                        .font(.title2)
                        .foregroundColor(.secondary)
                    
                    if isRefreshing {
                        ProgressView()
                            .scaleEffect(0.5)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredLogEntries, id: \.id) { entry in
                                LogEntryRow(entry: entry)
                                    .id(entry.id)
                                    .onTapGesture(count: 2) {
                                        copyToClipboard(entry.message)
                                    }
                                    .contextMenu {
                                        Button(L("log_menu_copy")) {
                                            copyToClipboard(entry.message)
                                        }
                                        Divider()
                                        Button(L("log_menu_copy_full")) {
                                            copyToClipboard("[\(entry.timestamp)] [\(entry.level)] \(entry.message)")
                                        }
                                    }
                            }
                        }
                    }
                    .onChange(of: logEntries.count) { _ in
                        if autoScroll, let lastEntry = filteredLogEntries.last {
                            withAnimation {
                                proxy.scrollTo(lastEntry.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: selectedLevel) { _ in filterLogs() }
        .onChange(of: searchText) { _ in filterLogs() }
        .onAppear {
            refreshLogs()
            startAutoRefresh()
        }
        .onDisappear {
            stopAutoRefresh()
        }
        .sheet(isPresented: $showExportSheet) {
            ExportLogSheet(logEntries: filteredLogEntries, category: category)
        }
    }
    
    private func refreshLogs() {
        isRefreshing = true
        Task {
            await loadLogs()
            isRefreshing = false
        }
    }
    
    private func clearLogs() {
        guard let logFilePath = Logger.shared.getLogFilePath(for: category) else { return }
        
        Task {
            do {
                try "".write(to: URL(fileURLWithPath: logFilePath), atomically: true, encoding: .utf8)
                await MainActor.run {
                    logEntries = []
                    filteredLogEntries = []
                }
            } catch {
                await MainActor.run {
                    logEntries = []
                    filteredLogEntries = []
                }
            }
        }
    }
    
    private func loadLogs() async {
        guard let logFilePath = Logger.shared.getLogFilePath(for: category) else {
            await MainActor.run {
                logEntries = []
                filterLogs()
            }
            return
        }
        
        do {
            let content = try String(contentsOfFile: logFilePath, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            
            let entries = lines.compactMap { line -> LogEntry? in
                return parseLogLine(line)
            }
            
            await MainActor.run {
                logEntries = entries
                filterLogs()
            }
        } catch {
            await MainActor.run {
                logEntries = []
                filterLogs()
            }
        }
    }
    
    private func parseLogLine(_ line: String) -> LogEntry? {
        guard !line.isEmpty else { return nil }
        
        let pattern = #"^\[([^\]]+)\] \[([^\]]+)\] (.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return LogEntry(
                id: UUID().uuidString,
                timestamp: Date(),
                level: "INFO",
                message: line
            )
        }
        
        let timestampStr = (line as NSString).substring(with: match.range(at: 1))
        let levelStr = (line as NSString).substring(with: match.range(at: 2))
        let message = (line as NSString).substring(with: match.range(at: 3))
        
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.date(from: timestampStr) ?? Date()
        
        return LogEntry(
            id: UUID().uuidString,
            timestamp: timestamp,
            level: levelStr,
            message: message
        )
    }
    
    private func filterLogs() {
        filteredLogEntries = logEntries.filter { entry in
            if selectedLevel != .all && entry.level != selectedLevel.rawValue {
                return false
            }
            
            if !searchText.isEmpty && !entry.message.localizedCaseInsensitiveContains(searchText) {
                return false
            }
            
            return true
        }
    }
    
    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    
    private func startAutoRefresh() {
        $refreshTimer.wrappedValue?.invalidate()
        $refreshTimer.wrappedValue = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task {
                await loadLogs()
            }
        }
    }
    
    private func stopAutoRefresh() {
        $refreshTimer.wrappedValue?.invalidate()
        $refreshTimer.wrappedValue = nil
    }
}

struct LogEntryRow: View {
    let entry: LogEntry
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.levelIcon)
                    .font(.system(size: 14))
                
                Text(entry.timestamp, style: .time)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text(entry.timestamp, style: .date)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            
            Text(entry.message)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .background(rowBackgroundColor)
        .cornerRadius(8)
    }
    
    private var rowBackgroundColor: Color {
        switch entry.level {
        case "❌ ERROR":
            return Color.red.opacity(0.08)
        case "⚠️ WARNING":
            return Color.orange.opacity(0.08)
        case "✅ SUCCESS":
            return Color.green.opacity(0.08)
        case "🔍 DEBUG":
            return Color.blue.opacity(0.05)
        default:
            return Color.clear
        }
    }
}

struct ExportLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var localization = LocalizationManager.shared
    let logEntries: [LogEntry]
    let category: Logger.Category
    @State private var selectedExportType: ExportType = .text
    
    var body: some View {
        VStack(spacing: 20) {
            Text(L("log_export"))
                .font(.headline)
            
            Picker(L("log_export_format"), selection: $selectedExportType) {
                ForEach(ExportType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)
            
            Text(L("log_export_count_desc", logEntries.count))
                .foregroundColor(.secondary)
            
            HStack {
                Button(L("cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button(L("log_export_btn")) {
                    exportLogs()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 450, height: 250)
    }
    
    private func exportLogs() {
        let content: String
        
        switch selectedExportType {
        case .text:
            content = logEntries.map { "[\($0.timestamp)] [\($0.level)] \($0.message)" }.joined(separator: "\n")
        case .json:
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(logEntries),
               let json = String(data: data, encoding: .utf8) {
                content = json
            } else {
                content = L("log_export_failed")
            }
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "\(category.rawValue)-\(dateFormatter.string(from: Date())).\(selectedExportType.fileExtension)"
        
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText, .json]
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true
        
        if panel.runModal() == .OK, let url = panel.url {
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

struct LogEntry: Identifiable, Codable {
    let id: String
    let timestamp: Date
    let level: String
    let message: String
    
    var levelIcon: String {
        switch level {
        case "🔍 DEBUG":
            return "🔍"
        case "ℹ️ INFO":
            return "ℹ️"
        case "⚠️ WARNING":
            return "⚠️"
        case "❌ ERROR":
            return "❌"
        case "✅ SUCCESS":
            return "✅"
        default:
            return "ℹ️"
        }
    }
}

enum LogLevelFilter: String, CaseIterable {
    case all = "all"
    case debug = "🔍 DEBUG"
    case info = "ℹ️ INFO"
    case warning = "⚠️ WARNING"
    case error = "❌ ERROR"
    case success = "✅ SUCCESS"
    
    var displayName: String {
        if self == .all {
            return L("log_level_all")
        }
        return rawValue
    }
}

enum ExportType: String, CaseIterable {
    case text = "text"
    case json = "json"
    
    var displayName: String {
        switch self {
        case .text: return L("log_export_type_text")
        case .json: return "JSON"
        }
    }
    
    var fileExtension: String {
        switch self {
        case .text:
            return "txt"
        case .json:
            return "json"
        }
    }
}

extension Logger.Category {
    var displayName: String {
        switch self {
        case .system:
            return L("cat_system")
        case .fileOps:
            return L("cat_file_ops")
        case .webdav:
            return L("cat_webdav")
        case .cache:
            return L("cat_cache")
        case .database:
            return L("cat_database")
        case .sync:
            return L("cat_sync")
        }
    }
}

struct FileOperationsPanel: View {
    @ObservedObject private var operationManager = FileOperationManager.shared
    @ObservedObject private var localization = LocalizationManager.shared
    @State private var selectedFilter: OperationFilter = .all
    
    var filteredOperations: [FileOperationItem] {
        switch selectedFilter {
        case .all:
            return operationManager.operations
        case .inProgress:
            return operationManager.inProgressOperations
        case .pending:
            return operationManager.pendingOperations
        case .failed:
            return operationManager.failedOperations
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("log_file_ops_panel_title"))
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Picker(L("log_file_ops_filter"), selection: $selectedFilter) {
                    ForEach(OperationFilter.allCases, id: \.self) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                
                Button(action: { operationManager.clearAllOperations() }) {
                    Image(systemName: "trash")
                }
                .help(L("log_file_ops_clear_all"))
                .disabled(operationManager.operations.isEmpty)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            if filteredOperations.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "tray")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                    
                    Text(L("log_file_ops_empty"))
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: 200)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredOperations) { operation in
                            FileOperationRow(operation: operation)
                        }
                    }
                    .padding()
                }
                .frame(maxHeight: 300)
            }
        }
    }
}

struct FileOperationRow: View {
    let operation: FileOperationItem
    @ObservedObject private var localization = LocalizationManager.shared
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: operation.type.icon)
                .font(.system(size: 20))
                .foregroundColor(.accentColor)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(operation.fileName)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Text(operation.type.localizedDisplayName)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.1))
                        .foregroundColor(.accentColor)
                        .cornerRadius(4)
                }
                
                HStack {
                    Text(operation.filePath)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Text(statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(statusColor)
                }
                
                if operation.status == .inProgress || operation.progress > 0 {
                    ProgressView(value: operation.progress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .accentColor))
                }
            }
            
            Image(systemName: operation.status.icon)
                .font(.system(size: 16))
                .foregroundColor(statusColor)
        }
        .padding(12)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
    }
    
    private var statusText: String {
        switch operation.status {
        case .pending:
            return L("file_op_status_pending")
        case .inProgress:
            return L("file_op_status_progress", Int(operation.progress * 100))
        case .completed:
            if let completedAt = operation.completedAt {
                let duration = completedAt.timeIntervalSince(operation.createdAt)
                return L("file_op_status_completed_duration", String(format: "%.1f", duration))
            }
            return L("file_op_status_completed")
        case .failed:
            return L("file_op_status_failed")
        case .cancelled:
            return L("file_op_status_cancelled")
        }
    }
    
    private var statusColor: Color {
        Color(hex: operation.status.color)
    }
}

enum OperationFilter: String, CaseIterable {
    case all = "all"
    case inProgress = "inProgress"
    case pending = "pending"
    case failed = "failed"
    
    var displayName: String {
        switch self {
        case .all: return L("log_level_all")
        case .inProgress: return L("file_op_filter_in_progress")
        case .pending: return L("file_op_filter_pending")
        case .failed: return L("file_op_filter_failed")
        }
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
