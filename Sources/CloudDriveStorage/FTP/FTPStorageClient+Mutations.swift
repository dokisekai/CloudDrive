import Foundation
import CloudDriveContracts
import CloudDriveSupport
import Network
import UniformTypeIdentifiers

extension FTPStorageClient {
    public func createDirectory(path: String) async throws {
        let ftpPath = resolveFTPPath(path)
        if ftpPath == "/" { return }
        
        try await executeFTPCommand { conn in
            let resp = try await conn.sendCommand("MKD \(ftpPath)")
            // 257: 目录已创建, 550: 目录已存在
            if resp.code != 257 && resp.code != 550 {
                throw StorageError.invalidOperation
            }
        }
    }
    
    public func delete(path: String) async throws {
        let ftpPath = resolveFTPPath(path)
        if ftpPath == "/" { return }
        
        try await executeFTPCommand { conn in
            // 先尝试删除文件
            let delResp = try await conn.sendCommand("DELE \(ftpPath)")
            if delResp.code != 250 {
                // 如果不是文件，尝试删除目录
                let rmdResp = try await conn.sendCommand("RMD \(ftpPath)")
                if rmdResp.code != 250 && rmdResp.code != 550 {
                    throw StorageError.invalidOperation
                }
            }
        }
    }
    
    public func move(from sourcePath: String, to destinationPath: String) async throws {
        let src = resolveFTPPath(sourcePath)
        let dst = resolveFTPPath(destinationPath)
        if src == dst { return }
        
        try await executeFTPCommand { conn in
            let rnfr = try await conn.sendCommand("RNFR \(src)")
            guard rnfr.code == 350 else {
                throw StorageError.notFound
            }
            let rnto = try await conn.sendCommand("RNTO \(dst)")
            guard rnto.code == 250 else {
                throw StorageError.invalidOperation
            }
        }
    }
}
