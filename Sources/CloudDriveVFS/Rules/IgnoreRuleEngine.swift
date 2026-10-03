//
//  IgnoreRuleEngine.swift
//  CloudDriveCore
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  三层协同忽略规则引擎（内置规则 + 软件全局规则 + 加密库级规则 + 访达排除）
//

import Foundation

public enum IgnoreRuleSource: String, Codable, Comparable, Sendable {
    case builtin   = "builtin"    // 内置系统元数据规则
    case global    = "global"     // 软件级全局规则（对所有加密库生效）
    case vault     = "vault"      // 加密库规则（来自 .clouddriveignore）
    case user      = "user"       // 访达用户右键手动排除（最高优先级）
    
    public static func < (lhs: Self, rhs: Self) -> Bool {
        let order: [Self] = [.builtin, .global, .vault, .user]
        let leftIdx = order.firstIndex(of: lhs) ?? 0
        let rightIdx = order.firstIndex(of: rhs) ?? 0
        return leftIdx < rightIdx
    }
}

public struct IgnoreRule: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let pattern: String        // 规则原模式，如 "target/", "*.pyc", "!important.log"
    public let cleanPattern: String   // 去除前导 ! 的纯模式
    public let source: IgnoreRuleSource
    public let isNegation: Bool       // 是否为 ! 开头的反向放行规则
    public let comment: String?
    
    public init(pattern: String, source: IgnoreRuleSource, comment: String? = nil) {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        self.id = UUID().uuidString
        self.isNegation = trimmed.hasPrefix("!")
        self.pattern = trimmed
        self.cleanPattern = isNegation ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmed
        self.source = source
        self.comment = comment
    }
}

public final class IgnoreRuleEngine {
    public static let shared = IgnoreRuleEngine()
    
    private let lock = NSLock()
    
    // MARK: - 0. 内置硬编码系统规则 (Builtin)
    
    public static let builtinRules: [IgnoreRule] = [
        // macOS 系统文件
        IgnoreRule(pattern: ".DS_Store", source: .builtin, comment: "macOS 文件夹元数据"),
        IgnoreRule(pattern: "._*", source: .builtin, comment: "macOS 资源 Fork 文件"),
        IgnoreRule(pattern: ".AppleDouble", source: .builtin, comment: "AppleDouble 目录"),
        IgnoreRule(pattern: ".Trashes", source: .builtin, comment: "macOS 废纸篓"),
        IgnoreRule(pattern: ".Spotlight-V100", source: .builtin, comment: "Spotlight 索引"),
        IgnoreRule(pattern: ".fseventsd", source: .builtin, comment: "FSEvents 事件流"),
        
        // Windows 系统文件
        IgnoreRule(pattern: "Thumbs.db", source: .builtin, comment: "Windows 缩略图数据库"),
        IgnoreRule(pattern: "desktop.ini", source: .builtin, comment: "Windows 文件夹配置"),
        IgnoreRule(pattern: "ehthumbs.db", source: .builtin, comment: "Windows 媒体缩略图"),
        IgnoreRule(pattern: "$RECYCLE.BIN/", source: .builtin, comment: "Windows 回收站"),
        
        // Office temporary lock files
        IgnoreRule(pattern: "~$*", source: .builtin, comment: "Microsoft Office temporary lock file"),
    ]
    
    // MARK: - 开发者常用预设模板
    
    public static let developerPresets: [String: [String]] = [
        "Node.js": [
            "node_modules/",
            ".npm/",
            ".yarn/",
            ".pnpm-store/",
            "bower_components/"
        ],
        "Rust": [
            "target/",
            "**/*.rs.bk"
        ],
        "Java / Kotlin / Gradle": [
            "target/",
            "build/",
            ".gradle/",
            "out/",
            "*.class"
        ],
        "Python": [
            "__pycache__/",
            "*.py[cod]",
            "*$py.class",
            ".venv/",
            "venv/",
            "env/",
            ".tox/",
            "*.egg-info/",
            ".pytest_cache/"
        ],
        "Swift / Xcode": [
            "DerivedData/",
            "*.xcworkspace/xcuserdata/",
            "*.xcuserdatad/",
            ".build/"
        ],
        "IDE 配置": [
            ".idea/",
            ".vscode/",
            "*.iml",
            "*.swp",
            "*.swo",
            "*~"
        ],
        "版本控制 (VCS)": [
            ".git/",
            ".svn/",
            ".hg/"
        ],
        "通用缓存与日志": [
            ".cache/",
            "tmp/",
            "temp/",
            "*.tmp",
            "*.log",
            "*.bak"
        ]
    ]
    
    // MARK: - 内部规则存储
    
    /// 全局规则列表
    private var globalRules: [IgnoreRule] = []
    
    /// 库级规则映射表 (vaultId -> [IgnoreRule])
    private var vaultRules: [String: [IgnoreRule]] = [:]
    
    /// 用户在访达右键手动排除的文件/目录列表 (vaultId -> Set<relativePath>)
    private var userExclusions: [String: Set<String>] = [:]
    
    /// 是否启用内置规则
    public var enableBuiltinRules: Bool = true
    
    private init() {
        loadGlobalRulesFromSettings()
    }
    
    // MARK: - 全局规则管理 (软件级别)
    
    public func setGlobalPatterns(_ patterns: [String]) {
        lock.lock()
        defer { lock.unlock() }
        
        self.globalRules = patterns.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            return IgnoreRule(pattern: trimmed, source: .global)
        }
    }
    
    public func getGlobalPatterns() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return globalRules.map { $0.pattern }
    }
    
    public func loadGlobalRulesFromSettings() {
        let settingsFile = CloudDrivePaths.sharedDirectory.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: settingsFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let patterns = json["globalIgnorePatterns"] as? [String] else {
            // 若没有设置，默认注入基础开发者预设（如 node_modules/, target/, .git/ 等）
            let defaults = ["node_modules/", "target/", ".git/", ".idea/", ".vscode/", ".cache/", "*.log"]
            setGlobalPatterns(defaults)
            return
        }
        setGlobalPatterns(patterns)
    }
    
    // MARK: - 加密库规则管理 (库级别，来自 .clouddriveignore)
    
    public func setVaultRules(vaultId: String, content: String) {
        lock.lock()
        defer { lock.unlock() }
        
        let rules = parseIgnoreContent(content, source: .vault)
        self.vaultRules[vaultId] = rules
    }
    
    public func getVaultRules(vaultId: String) -> [IgnoreRule] {
        lock.lock()
        defer { lock.unlock() }
        return vaultRules[vaultId] ?? []
    }
    
    public func parseIgnoreContent(_ content: String, source: IgnoreRuleSource) -> [IgnoreRule] {
        return content.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            return IgnoreRule(pattern: trimmed, source: source)
        }
    }
    
    // MARK: - 访达用户排除管理 (Level 3)
    
    public func setUserExcluded(vaultId: String, path: String, isExcluded: Bool) {
        lock.lock()
        defer { lock.unlock() }
        
        let normPath = normalizePath(path)
        var set = userExclusions[vaultId] ?? Set<String>()
        if isExcluded {
            set.insert(normPath)
        } else {
            set.remove(normPath)
        }
        userExclusions[vaultId] = set
        saveUserExclusions(vaultId: vaultId)
    }
    
    public func isUserExcluded(vaultId: String, path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        let normPath = normalizePath(path)
        guard let set = userExclusions[vaultId] else { return false }
        
        // 检查自身或任意父级目录是否在排除名单中
        if set.contains(normPath) { return true }
        var current = normPath
        while current.contains("/") {
            current = (current as NSString).deletingLastPathComponent
            if set.contains(current) { return true }
        }
        return false
    }
    
    public func loadUserExclusions(vaultId: String) {
        let file = CloudDrivePaths.sharedDirectory.appendingPathComponent("ignore_exclusions_\(vaultId).json")
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        lock.lock()
        userExclusions[vaultId] = Set(list.map { normalizePath($0) })
        lock.unlock()
    }
    
    private func saveUserExclusions(vaultId: String) {
        let set = userExclusions[vaultId] ?? []
        let file = CloudDrivePaths.sharedDirectory.appendingPathComponent("ignore_exclusions_\(vaultId).json")
        if let data = try? JSONEncoder().encode(Array(set)) {
            try? data.write(to: file, options: .atomic)
        }
    }
    
    // MARK: - 核心判定逻辑 (Core Matching)
    
    /// 判定指定路径是否应该被忽略
    /// - Parameters:
    ///   - path: 文件或目录的完整相对路径（如 "my-project/node_modules/lodash/index.js"）
    ///   - name: 文件或目录名（如 "node_modules"）
    ///   - isDirectory: 是否为文件夹
    ///   - vaultId: 所属 Vault ID
    public func shouldIgnore(path: String, name: String, isDirectory: Bool, vaultId: String) -> Bool {
        // 规则文件自身从不被忽略（保证可读取和更新）
        if name == ".clouddriveignore" {
            return false
        }
        
        // 目录级缩略图清单包在访达中默认隐身，不干扰用户正常视图
        if name == ".thumbnails.catalog" {
            return true
        }
        
        let normPath = normalizePath(path)
        
        // 1. 用户手动排除（最高优先级，直接忽略）
        if isUserExcluded(vaultId: vaultId, path: normPath) {
            return true
        }
        
        lock.lock()
        var rulesToEvaluate: [IgnoreRule] = []
        if enableBuiltinRules {
            rulesToEvaluate.append(contentsOf: Self.builtinRules)
        }
        rulesToEvaluate.append(contentsOf: globalRules)
        if let vRules = vaultRules[vaultId] {
            rulesToEvaluate.append(contentsOf: vRules)
        }
        lock.unlock()
        
        var isIgnored = false
        
        // 按顺序评估规则，后出现的规则（包括 ! 取反规则）覆盖前出现的规则
        for rule in rulesToEvaluate {
            if matches(rule: rule, path: normPath, name: name, isDirectory: isDirectory) {
                isIgnored = !rule.isNegation
            }
        }
        
        return isIgnored
    }
    
    // MARK: - 单条规则匹配算法
    
    private func matches(rule: IgnoreRule, path: String, name: String, isDirectory: Bool) -> Bool {
        var pattern = rule.cleanPattern
        
        // 1. 如果 pattern 以 / 结尾，则此规则仅对目录生效
        if pattern.hasSuffix("/") {
            if !isDirectory && !path.hasSuffix("/") {
                // 如果当前项不是目录，但上层路径中包含该目录模式，依然匹配
                let dirPattern = String(pattern.dropLast())
                if matchesPathComponent(pattern: dirPattern, path: path) {
                    return true
                }
                return false
            }
            pattern = String(pattern.dropLast())
        }
        
        // 2. 如果 pattern 不包含 /，则匹配任意层级的同名文件/目录
        if !pattern.contains("/") {
            // 对当前名称匹配
            if fnmatch(pattern: pattern, text: name) {
                return true
            }
            // 对路径中的任何一级组件匹配（例如 node_modules/ 下的子文件）
            let components = path.components(separatedBy: "/")
            for comp in components where !comp.isEmpty {
                if fnmatch(pattern: pattern, text: comp) {
                    return true
                }
            }
            return false
        }
        
        // 3. 如果 pattern 以 / 开头，表示从根路径起匹配
        if pattern.hasPrefix("/") {
            let rootPattern = String(pattern.dropFirst())
            return fnmatch(pattern: rootPattern, text: path)
        }
        
        // 4. 包含 / 但不以 / 开头的路径，支持跨层级匹配
        if fnmatch(pattern: pattern, text: path) {
            return true
        }
        
        // 允许通配子路径匹配 (例如 "target/debug" 匹配 "app/target/debug/app.o")
        return path.contains(pattern)
    }
    
    private func matchesPathComponent(pattern: String, path: String) -> Bool {
        let comps = path.components(separatedBy: "/")
        for comp in comps where !comp.isEmpty {
            if fnmatch(pattern: pattern, text: comp) {
                return true
            }
        }
        return false
    }
    
    /// 标准 Glob 单层/跨层通配符匹配算法
    private func fnmatch(pattern: String, text: String) -> Bool {
        if pattern == text { return true }
        if pattern == "*" && !text.isEmpty { return true }
        
        // 转义正则表达式特殊字符，保留 * 与 ?
        var regexStr = "^"
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let c = pattern[i]
            switch c {
            case "*":
                let next = pattern.index(after: i)
                if next < pattern.endIndex && pattern[next] == "*" {
                    // ** 匹配任意字符（包括 /）
                    regexStr += ".*"
                    i = pattern.index(after: next)
                    continue
                } else {
                    // * 匹配除了 / 以外的字符
                    regexStr += "[^/]*"
                }
            case "?":
                regexStr += "[^/]"
            case ".", "(", ")", "+", "|", "^", "$", "@", "%":
                regexStr += "\\\(c)"
            case "[", "]":
                regexStr += String(c)
            default:
                regexStr += String(c)
            }
            i = pattern.index(after: i)
        }
        regexStr += "$"
        
        guard let regex = try? NSRegularExpression(pattern: regexStr, options: [.caseInsensitive]) else {
            return pattern.lowercased() == text.lowercased()
        }
        
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
    
    private func normalizePath(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while p.hasPrefix("/") { p = String(p.dropFirst()) }
        while p.hasSuffix("/") { p = String(p.dropLast()) }
        return p
    }
}
