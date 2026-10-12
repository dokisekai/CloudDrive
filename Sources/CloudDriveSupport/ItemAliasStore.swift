import Foundation

/// 线程安全的文件/目录 ID 别名重定向存储
/// 用于在移动、重命名、占位符转正式 ID 期间平滑过渡，杜绝系统拿旧 ID 请求时发生 -1005 (noSuchItem)
public final class ItemAliasStore: @unchecked Sendable {
    public static let shared = ItemAliasStore()
    
    private struct AliasEntry {
        let targetId: String
        let recordedAt: Date
    }
    
    private let lock = NSLock()
    private var aliases: [String: AliasEntry] = [:]
    private let maxEntries: Int = 2000
    private let ttlSeconds: TimeInterval = 600 // 10 分钟 TTL，足以平滑过渡 Finder 和 fileproviderd 的短时缓存
    
    private init() {}
    
    /// 记录旧 ID 到新 ID 的重定向关系
    public func recordAlias(from sourceId: String, to targetId: String) {
        guard !sourceId.isEmpty, !targetId.isEmpty, sourceId != targetId else { return }
        
        lock.lock()
        defer { lock.unlock() }
        
        pruneExpiredIfNeeded()
        
        let now = Date()
        // 链式扁平化：如果 sourceId 已经指向了某个链，或 targetId 自身又指向了别的目标
        let resolvedTarget = resolveInternal(targetId)
        guard sourceId != resolvedTarget else { return } // 防环
        
        aliases[sourceId] = AliasEntry(targetId: resolvedTarget, recordedAt: now)
        
        // 更新所有原来指向 sourceId 的旧别名，直指最终的 resolvedTarget
        for (key, entry) in aliases where entry.targetId == sourceId {
            aliases[key] = AliasEntry(targetId: resolvedTarget, recordedAt: now)
        }
        
        // 超出最大容量时淘汰最旧的一批
        if aliases.count > maxEntries {
            let sortedKeys = aliases.sorted { $0.value.recordedAt < $1.value.recordedAt }
            let removeCount = aliases.count - maxEntries + 100
            for pair in sortedKeys.prefix(removeCount) {
                aliases.removeValue(forKey: pair.key)
            }
        }
    }
    
    /// 解析 ID。若存在有效别名重定向，返回最新目标 ID；否则返回原 ID
    public func resolve(_ id: String) -> String {
        guard !id.isEmpty else { return id }
        lock.lock()
        defer { lock.unlock() }
        return resolveInternal(id)
    }
    
    /// 检查指定 ID 是否存在别名目标
    public func hasAlias(for id: String) -> Bool {
        guard !id.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        if let entry = aliases[id], Date().timeIntervalSince(entry.recordedAt) <= ttlSeconds {
            return true
        }
        return false
    }
    
    /// 移除针对该 ID 的所有别名记录（例如文件被彻底删除时）
    public func removeAlias(for id: String) {
        guard !id.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        aliases.removeValue(forKey: id)
        // 同时也清理反向指向该 id 的别名
        for (key, entry) in aliases where entry.targetId == id {
            aliases.removeValue(forKey: key)
        }
    }
    
    /// 清空所有别名
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        aliases.removeAll()
    }
    
    // MARK: - Internal
    
    private func resolveInternal(_ id: String) -> String {
        var current = id
        var visited = Set<String>()
        let now = Date()
        
        while let entry = aliases[current] {
            // 检查过期
            if now.timeIntervalSince(entry.recordedAt) > ttlSeconds {
                aliases.removeValue(forKey: current)
                break
            }
            if visited.contains(entry.targetId) {
                // 检测到环，中断
                break
            }
            visited.insert(current)
            current = entry.targetId
        }
        return current
    }
    
    private func pruneExpiredIfNeeded() {
        let now = Date()
        var expiredKeys: [String] = []
        for (key, entry) in aliases {
            if now.timeIntervalSince(entry.recordedAt) > ttlSeconds {
                expiredKeys.append(key)
            }
        }
        for key in expiredKeys {
            aliases.removeValue(forKey: key)
        }
    }
}
