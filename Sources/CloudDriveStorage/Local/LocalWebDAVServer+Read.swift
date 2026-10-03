import Foundation
import CloudDriveContracts
import CloudDriveSupport
import Network

extension LocalWebDAVServer {
    func handleGet(localURL: URL, headers: [String: String], isHead: Bool, connection: NWConnection) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: localURL.path) else {
            sendResponse(connection: connection, status: "404 Not Found", headers: ["Content-Length": "0"], body: nil)
            return
        }
        
        let attrs = (try? fm.attributesOfItem(atPath: localURL.path)) ?? [:]
        let totalSize = (attrs[.size] as? Int64) ?? 0
        
        // 处理 Range 请求 (例如: Range: bytes=0-1024)
        if let rangeHeader = headers["range"], rangeHeader.hasPrefix("bytes=") {
            let spec = rangeHeader.dropFirst(6)
            let rangeParts = spec.split(separator: "-", omittingEmptySubsequences: false)
            if let startStr = rangeParts.first, let start = Int64(startStr) {
                let end = (rangeParts.count > 1 && !rangeParts[1].isEmpty) ? (Int64(rangeParts[1]) ?? (totalSize - 1)) : (totalSize - 1)
                let validEnd = min(end, totalSize - 1)
                let length = validEnd - start + 1
                
                if length > 0 && start < totalSize {
                    if isHead {
                        sendResponse(connection: connection, status: "206 Partial Content", headers: [
                            "Content-Range": "bytes \(start)-\(validEnd)/\(totalSize)",
                            "Content-Length": "\(length)",
                            "Content-Type": "application/octet-stream"
                        ], body: nil)
                        return
                    }
                    
                    if let handle = try? FileHandle(forReadingFrom: localURL) {
                        try? handle.seek(toOffset: UInt64(start))
                        let chunk = handle.readData(ofLength: Int(length))
                        try? handle.close()
                        sendResponse(connection: connection, status: "206 Partial Content", headers: [
                            "Content-Range": "bytes \(start)-\(validEnd)/\(totalSize)",
                            "Content-Length": "\(chunk.count)",
                            "Content-Type": "application/octet-stream"
                        ], body: chunk)
                        return
                    }
                }
            }
        }
        
        // 完整文件
        if isHead {
            sendResponse(connection: connection, status: "200 OK", headers: [
                "Content-Length": "\(totalSize)",
                "Content-Type": "application/octet-stream"
            ], body: nil)
            return
        }
        
        do {
            let data = try Data(contentsOf: localURL)
            sendResponse(connection: connection, status: "200 OK", headers: [
                "Content-Length": "\(data.count)",
                "Content-Type": "application/octet-stream"
            ], body: data)
        } catch {
            logError(.system, "❌ LocalWebDAV handleGet read failed [\(localURL.path)]: \(error)")
            sendResponse(connection: connection, status: "500 Internal Server Error", headers: ["Content-Length": "0"], body: nil)
        }
    }
}
