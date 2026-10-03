import Foundation
import CloudDriveContracts
import CloudDriveSupport
import Network

extension LocalWebDAVServer {
    // MARK: - 辅助处理
    
    func resolveVaultRouting(path: String) -> (vaultId: String, subPath: String)? {
        let clean = path.removingPercentEncoding ?? path
        
        // 格式 1: /v/<vaultId>/...
        if clean.hasPrefix("/v/") {
            let afterV = clean.dropFirst(3)
            let components = afterV.split(separator: "/", maxSplits: 1)
            if let first = components.first {
                let vId = String(first)
                let sub = components.count > 1 ? "/" + String(components[1]) : "/"
                return (vId, sub)
            }
        }
        
        // 格式 2: 回退默认
        lock.lock()
        let defaultId = registeredVaults.keys.first ?? "default"
        lock.unlock()
        return (defaultId, clean)
    }
}
