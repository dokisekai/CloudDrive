import Foundation
import CloudDriveContracts
import CloudDriveSupport
import Network
import UniformTypeIdentifiers

extension FTPStorageClient {
    // MARK: - StorageClient Implementation
    
    public func exists(path: String) async throws -> Bool {
        let ftpPath = resolveFTPPath(path)
        if ftpPath == "/" { return true }
        
        var found = false
        try? await executeFTPCommand { conn in
            // 尝试检查文件大小
            let sizeResp = try await conn.sendCommand("SIZE \(ftpPath)")
            if sizeResp.code == 213 {
                found = true
                return
            }
            // 尝试检查目录是否存在
            let cwdResp = try await conn.sendCommand("CWD \(ftpPath)")
            if cwdResp.code == 250 {
                found = true
                return
            }
        }
        return found
    }
    
    public func listDirectory(path: String) async throws -> [StorageResource] {
        guard let url = buildFTPURL(for: path) else {
            throw StorageError.invalidOperation
        }
        
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw StorageError.serverError(statusCode: http.statusCode, message: "FTP list failed: HTTP \(http.statusCode)")
        }
        
        guard let listString = String(data: data, encoding: .utf8), !listString.isEmpty else {
            return []
        }
        
        return parseFTPList(listString, basePath: path)
    }
}
