import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit
import UniformTypeIdentifiers

extension Pan123StorageClient {
    // MARK: - Node & Directory Resolution
    
    /// 解析指定路径对应的云盘文件节点
    func resolveNode(for path: String) async throws -> Pan123FileItem {
        let canonical = normalizePath(path)
        if canonical == "/" {
            return Pan123FileItem(
                fileId: config.rootFolderID,
                filename: "",
                parentFileId: 0,
                type: 1,
                size: 0
            )
        }
        
        if let cached = cache.getNode(for: canonical) {
            return cached
        }
        
        // 逐级向下解析
        let components = canonical.split(separator: "/").map(String.init)
        var currentParentId = config.rootFolderID
        var currentItem: Pan123FileItem?
        var accumulatedPath = ""
        
        for (index, component) in components.enumerated() {
            accumulatedPath += "/\(component)"
            
            // 检查当前组件的节点是否已有缓存
            if let cachedNode = cache.getNode(for: accumulatedPath) {
                currentItem = cachedNode
                currentParentId = cachedNode.fileId
                continue
            }
            
            // 获取当前父目录下的所有项
            let items: [Pan123FileItem]
            if let cachedChildren = cache.getChildren(for: currentParentId) {
                items = cachedChildren
            } else {
                items = try await fetchFileList(parentFileId: currentParentId)
                cache.setChildren(for: currentParentId, items: items)
            }
            
            guard let matched = items.first(where: { $0.filename == component }) else {
                throw StorageError.notFound
            }
            
            cache.setNode(for: accumulatedPath, item: matched)
            currentItem = matched
            currentParentId = matched.fileId
            
            // 如果不是最后一级，必须是目录
            if index < components.count - 1 && !matched.isDirectory {
                throw StorageError.invalidOperation
            }
        }
        
        guard let finalItem = currentItem else {
            throw StorageError.notFound
        }
        
        return finalItem
    }
    
    /// 拉取指定父目录下的全部未删除文件/目录（支持自动翻页）
    func fetchFileList(parentFileId: Int64) async throws -> [Pan123FileItem] {
        var allItems: [Pan123FileItem] = []
        var lastFileId: Int64? = nil
        
        while true {
            var queryItems = [
                URLQueryItem(name: "parentFileId", value: String(parentFileId)),
                URLQueryItem(name: "limit", value: "100")
            ]
            if let lastId = lastFileId, lastId > 0 {
                queryItems.append(URLQueryItem(name: "lastFileId", value: String(lastId)))
            }
            
            let listData: Pan123FileListData = try await apiClient.sendRequest(
                path: "api/v2/file/list",
                method: "GET",
                queryItems: queryItems
            )
            
            if let items = listData.fileList {
                // 过滤掉已放入回收站的文件
                let activeItems = items.filter { !$0.isTrashed }
                allItems.append(contentsOf: activeItems)
            }
            
            // lastFileId 为 -1 或 0 或与上次相同时表示翻页结束
            if listData.lastFileId == -1 || listData.lastFileId == 0 || listData.lastFileId == lastFileId {
                break
            }
            lastFileId = listData.lastFileId
        }
        
        return allItems
    }
}
