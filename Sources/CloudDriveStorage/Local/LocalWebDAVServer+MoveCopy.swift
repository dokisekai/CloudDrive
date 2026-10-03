import Foundation
import CloudDriveContracts
import CloudDriveSupport
import Network

extension LocalWebDAVServer {
    func handleMoveOrCopy(localURL: URL, headers: [String: String], isMove: Bool, connection: NWConnection) {
        guard let destHeader = headers["destination"] else {
            sendResponse(connection: connection, status: "400 Bad Request", headers: ["Content-Length": "0"], body: nil)
            return
        }
        
        // 解析 Destination URL
        let destPath: String
        if let destURL = URL(string: destHeader) {
            destPath = destURL.path
        } else {
            destPath = destHeader
        }
        
        guard let (destVaultId, destSub) = resolveVaultRouting(path: destPath) else {
            sendResponse(connection: connection, status: "400 Bad Request", headers: ["Content-Length": "0"], body: nil)
            return
        }
        
        lock.lock()
        let destBaseURL = registeredVaults[destVaultId] ?? registeredVaults.values.first
        lock.unlock()
        
        guard let baseURL = destBaseURL else {
            sendResponse(connection: connection, status: "500 Internal Server Error", headers: ["Content-Length": "0"], body: nil)
            return
        }
        
        let cleanSub = destSub.hasPrefix("/") ? String(destSub.dropFirst()) : destSub
        var targetDestURL = baseURL
        for comp in cleanSub.split(separator: "/") {
            targetDestURL = targetDestURL.appendingPathComponent(String(comp))
        }
        
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: targetDestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: targetDestURL.path) {
                try fm.removeItem(at: targetDestURL)
            }
            if isMove {
                try fm.moveItem(at: localURL, to: targetDestURL)
            } else {
                try fm.copyItem(at: localURL, to: targetDestURL)
            }
            sendResponse(connection: connection, status: "201 Created", headers: ["Content-Length": "0"], body: nil)
        } catch {
            logError(.system, "❌ LocalWebDAV \(isMove ? "MOVE" : "COPY") failed: \(error)")
            sendResponse(connection: connection, status: "500 Internal Server Error", headers: ["Content-Length": "0"], body: nil)
        }
    }
}
