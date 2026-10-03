import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit
import UniformTypeIdentifiers

final class Pan123PathCache: @unchecked Sendable {
    private let lock = NSLock()
    private var nodeCache: [String: Pan123FileItem] = [:]
    private var childrenCache: [Int64: [Pan123FileItem]] = [:]
    
    func getNode(for canonicalPath: String) -> Pan123FileItem? {
        lock.lock()
        defer { lock.unlock() }
        return nodeCache[canonicalPath]
    }
    
    func setNode(for canonicalPath: String, item: Pan123FileItem) {
        lock.lock()
        defer { lock.unlock() }
        nodeCache[canonicalPath] = item
    }
    
    func getChildren(for parentFileId: Int64) -> [Pan123FileItem]? {
        lock.lock()
        defer { lock.unlock() }
        return childrenCache[parentFileId]
    }
    
    func setChildren(for parentFileId: Int64, items: [Pan123FileItem]) {
        lock.lock()
        defer { lock.unlock() }
        childrenCache[parentFileId] = items
    }
    
    func invalidateChildren(for parentFileId: Int64) {
        lock.lock()
        defer { lock.unlock() }
        childrenCache.removeValue(forKey: parentFileId)
    }
    
    func invalidate(path canonicalPath: String) {
        lock.lock()
        defer { lock.unlock() }
        if let node = nodeCache.removeValue(forKey: canonicalPath) {
            childrenCache.removeValue(forKey: node.fileId)
        }
        let prefix = canonicalPath.hasSuffix("/") ? canonicalPath : "\(canonicalPath)/"
        let toRemove = nodeCache.filter { key, _ in key.hasPrefix(prefix) }
        for (key, item) in toRemove {
            nodeCache.removeValue(forKey: key)
            childrenCache.removeValue(forKey: item.fileId)
        }
    }
    
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        nodeCache.removeAll()
        childrenCache.removeAll()
    }
}

