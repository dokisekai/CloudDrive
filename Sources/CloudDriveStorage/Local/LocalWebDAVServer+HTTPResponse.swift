import Foundation
import CloudDriveContracts
import CloudDriveSupport
import Network

extension LocalWebDAVServer {
    func sendResponse(connection: NWConnection, status: String, headers: [String: String], body: Data?) {
        var headerStr = "HTTP/1.1 \(status)\r\n"
        for (k, v) in headers {
            headerStr += "\(k): \(v)\r\n"
        }
        headerStr += "Connection: close\r\n\r\n"
        
        var respData = headerStr.data(using: .utf8) ?? Data()
        if let body = body {
            respData.append(body)
        }
        
        connection.send(content: respData, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }
}
