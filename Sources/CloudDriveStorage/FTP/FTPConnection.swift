import Foundation
import CloudDriveContracts
import CloudDriveSupport
import Network
import UniformTypeIdentifiers

final class FTPConnection {
        private let host: String
        private let port: UInt16
        private let useTLS: Bool
        private var connection: NWConnection?
        
        init(host: String, port: UInt16, useTLS: Bool) {
            self.host = host
            self.port = port
            self.useTLS = useTLS
        }
        
        func connect() async throws {
            let endpoint = NWEndpoint.hostPort(host: .init(host), port: .init(rawValue: port)!)
            let params: NWParameters
            if useTLS {
                params = .tls
            } else {
                params = .tcp
            }
            let conn = NWConnection(to: endpoint, using: params)
            self.connection = conn
            
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var resumed = false
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if !resumed {
                            resumed = true
                            continuation.resume()
                        }
                    case .failed(let err):
                        if !resumed {
                            resumed = true
                            continuation.resume(throwing: StorageError.networkError("FTP 连接失败: \(err)"))
                        }
                    case .cancelled:
                        if !resumed {
                            resumed = true
                            continuation.resume(throwing: StorageError.networkError("FTP 连接已取消"))
                        }
                    default:
                        break
                    }
                }
                conn.start(queue: .global())
            }
        }
        
        func disconnect() {
            connection?.cancel()
            connection = nil
        }
        
        func sendCommand(_ cmd: String) async throws -> (code: Int, line: String) {
            guard let conn = connection else {
                throw StorageError.notConfigured
            }
            let line = cmd.hasSuffix("\r\n") ? cmd : "\(cmd)\r\n"
            let data = Data(line.utf8)
            
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                conn.send(content: data, completion: .contentProcessed { err in
                    if let err = err {
                        continuation.resume(throwing: StorageError.networkError("发送指令失败: \(err)"))
                    } else {
                        continuation.resume()
                    }
                })
            }
            
            return try await readResponse()
        }
        
        func readResponse() async throws -> (code: Int, line: String) {
            guard let conn = connection else {
                throw StorageError.notConfigured
            }
            
            return try await withCheckedThrowingContinuation { continuation in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, err in
                    if let err = err {
                        continuation.resume(throwing: StorageError.networkError("读取响应失败: \(err)"))
                        return
                    }
                    guard let data = data, let str = String(data: data, encoding: .utf8) else {
                        continuation.resume(throwing: StorageError.networkError("空响应"))
                        return
                    }
                    let lines = str.components(separatedBy: "\r\n").filter { !$0.isEmpty }
                    let lastLine = lines.last ?? str
                    let codeStr = String(lastLine.prefix(3))
                    let code = Int(codeStr) ?? 0
                    continuation.resume(returning: (code, lastLine))
                }
            }
        }
    }
    
    /// 执行 FTP 登录会话
