import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit

extension Pan123APIClient {
    // MARK: - Multipart Slice Upload
    
    /// 发送分片上传请求 (multipart/form-data，支持 429 与 401 自动重试)
    public func uploadSlice(
        serverURLString: String,
        preuploadID: String,
        sliceNo: Int,
        sliceMD5: String,
        sliceData: Data
    ) async throws {
        let (data, _) = try await executeWithRetry { token in
            var serverURL = URL(string: serverURLString) ?? self.baseURL
            if !serverURLString.hasPrefix("http://") && !serverURLString.hasPrefix("https://") {
                serverURL = URL(string: "https://\(serverURLString)") ?? self.baseURL
            }
            let endpoint = serverURL.appendingPathComponent("upload/v2/file/slice")
            
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("open_platform", forHTTPHeaderField: "Platform")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            
            let boundary = "Boundary-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            
            var body = Data()
            func appendFormField(name: String, value: String) {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
                body.append("\(value)\r\n".data(using: .utf8)!)
            }
            
            appendFormField(name: "preuploadID", value: preuploadID)
            appendFormField(name: "sliceNo", value: String(sliceNo))
            appendFormField(name: "sliceMD5", value: sliceMD5)
            
            // 文件分片二进制流
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"slice\"; filename=\"slice_\(sliceNo).bin\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append(sliceData)
            body.append("\r\n".data(using: .utf8)!)
            body.append("--\(boundary)--\r\n".data(using: .utf8)!)
            
            request.httpBody = body
            return request
        }
        
        let apiResponse = try JSONDecoder().decode(Pan123Response<Pan123EmptyData>.self, from: data)
        if apiResponse.code != 0 {
            throw mapPan123Error(code: apiResponse.code, message: apiResponse.message)
        }
    }
}
