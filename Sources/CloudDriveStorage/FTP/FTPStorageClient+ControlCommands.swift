import Foundation
import CloudDriveContracts
import CloudDriveSupport
import Network
import UniformTypeIdentifiers

extension FTPStorageClient {
    // MARK: - FTP Control Connection Helper
    
    func executeFTPCommand(_ execute: (FTPConnection) async throws -> Void) async throws {
        let conn = FTPConnection(host: config.host, port: UInt16(config.port), useTLS: config.useTLS)
        try await conn.connect()
        defer { conn.disconnect() }
        
        // 读取 220 欢迎语
        let banner = try await conn.readResponse()
        guard banner.code == 220 else {
            throw StorageError.networkError("FTP 服务端异常响应: \(banner.line)")
        }
        
        // 发送 USER
        let userResp = try await conn.sendCommand("USER \(config.username)")
        if userResp.code == 331 {
            // 需要密码
            let passResp = try await conn.sendCommand("PASS \(config.password)")
            guard passResp.code == 230 else {
                throw StorageError.authenticationFailed
            }
        } else if userResp.code != 230 {
            throw StorageError.authenticationFailed
        }
        
        // 设置二进制模式
        _ = try? await conn.sendCommand("TYPE I")
        
        try await execute(conn)
        _ = try? await conn.sendCommand("QUIT")
    }
}
