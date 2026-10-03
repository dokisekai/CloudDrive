import Foundation
import CloudDriveContracts
import CloudDriveSupport
import Network

extension LocalWebDAVServer {
    // MARK: - 连接与 HTTP 解析
    
    func handleConnection(_ connection: NWConnection) {
        connection.start(queue: serverQueue)
        readRequest(connection: connection, accumulated: Data())
    }
    
    func readRequest(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            var data = accumulated
            if let content = content {
                data.append(content)
            }
            
            // 查找 HTTP 头部结束符 "\r\n\r\n"
            if let headerEndRange = data.range(of: "\r\n\r\n".data(using: .utf8)!) {
                let headerData = data.subdata(in: 0..<headerEndRange.lowerBound)
                let bodyData = data.subdata(in: headerEndRange.upperBound..<data.count)
                
                if let headerStr = String(data: headerData, encoding: .utf8) {
                    let headers = self.parseHeaders(headerStr)
                    let contentLength = Int(headers["content-length"] ?? "0") ?? 0
                    
                    // 如果 Body 数据未读全，继续读取
                    if bodyData.count < contentLength && !isComplete && error == nil {
                        self.readRemainingBody(connection: connection, headerStr: headerStr, body: bodyData, targetLength: contentLength)
                        return
                    }
                    
                    self.processRequest(headerStr: headerStr, headers: headers, body: bodyData, connection: connection)
                    return
                }
            }
            
            if !isComplete && error == nil {
                self.readRequest(connection: connection, accumulated: data)
            } else {
                connection.cancel()
            }
        }
    }
    
    func readRemainingBody(connection: NWConnection, headerStr: String, body: Data, targetLength: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            var updatedBody = body
            if let content = content {
                updatedBody.append(content)
            }
            if updatedBody.count >= targetLength || isComplete || error != nil {
                let headers = self.parseHeaders(headerStr)
                self.processRequest(headerStr: headerStr, headers: headers, body: updatedBody, connection: connection)
            } else {
                self.readRemainingBody(connection: connection, headerStr: headerStr, body: updatedBody, targetLength: targetLength)
            }
        }
    }
    
    func parseHeaders(_ headerStr: String) -> [String: String] {
        var headers: [String: String] = [:]
        let lines = headerStr.components(separatedBy: "\r\n")
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                headers[parts[0].lowercased()] = parts[1]
            }
        }
        return headers
    }
}
