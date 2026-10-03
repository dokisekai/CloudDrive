import Foundation
import CloudDriveContracts
import CloudDriveSupport
import CryptoKit
import UniformTypeIdentifiers

extension S3StorageClient {
    // MARK: - AWS SigV4 Signing
    
    func signRequest(_ request: inout URLRequest, host: String, payloadData: Data? = nil, payloadHash overrideHash: String? = nil) {
        let now = Date()
        let amzDate = isoDateFormatter.string(from: now)
        let dateStamp = shortDateFormatter.string(from: now)
        
        let payloadHash: String
        if let overrideHash {
            payloadHash = overrideHash
        } else if let data = payloadData {
            payloadHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } else {
            // 无 body 时默认空字符串哈希
            payloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        }
        
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        
        // 提取并排序头部
        var headersToSign: [(String, String)] = [
            ("host", host),
            ("x-amz-content-sha256", payloadHash),
            ("x-amz-date", amzDate)
        ]
        if let copySource = request.value(forHTTPHeaderField: "x-amz-copy-source") {
            headersToSign.append(("x-amz-copy-source", copySource))
        }
        if let contentType = request.value(forHTTPHeaderField: "Content-Type") {
            headersToSign.append(("content-type", contentType))
        }
        headersToSign.sort { $0.0 < $1.0 }
        
        let canonicalHeaders = headersToSign.map { "\($0.0):\($0.1)\n" }.joined()
        let signedHeaders = headersToSign.map { $0.0 }.joined(separator: ";")
        
        // 构造 Canonical Query String
        var canonicalQuery = ""
        if let query = request.url?.query, !query.isEmpty {
            let pairs = query.components(separatedBy: "&").map { item -> (String, String) in
                let parts = item.components(separatedBy: "=")
                let k = parts[0]
                let v = parts.count > 1 ? parts[1] : ""
                return (k, v)
            }.sorted { $0.0 < $1.0 }
            canonicalQuery = pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        }
        
        let httpMethod = request.httpMethod ?? "GET"
        let canonicalURI = request.url?.path.isEmpty == false ? (request.url?.path ?? "/") : "/"
        
        let canonicalRequest = """
        \(httpMethod)
        \(canonicalURI)
        \(canonicalQuery)
        \(canonicalHeaders)
        \(signedHeaders)
        \(payloadHash)
        """
        
        let canonicalRequestHash = SHA256.hash(data: Data(canonicalRequest.utf8)).map { String(format: "%02x", $0) }.joined()
        let credentialScope = "\(dateStamp)/\(config.region)/s3/aws4_request"
        let stringToSign = """
        AWS4-HMAC-SHA256
        \(amzDate)
        \(credentialScope)
        \(canonicalRequestHash)
        """
        
        // 派生签名密钥
        let kSecret = SymmetricKey(data: Data(("AWS4" + config.secretKey).utf8))
        let kDate = HMAC<SHA256>.authenticationCode(for: Data(dateStamp.utf8), using: kSecret)
        let kRegion = HMAC<SHA256>.authenticationCode(for: Data(config.region.utf8), using: SymmetricKey(data: kDate))
        let kService = HMAC<SHA256>.authenticationCode(for: Data("s3".utf8), using: SymmetricKey(data: kRegion))
        let kSigning = HMAC<SHA256>.authenticationCode(for: Data("aws4_request".utf8), using: SymmetricKey(data: kService))
        
        let signature = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: SymmetricKey(data: kSigning))
        let signatureHex = signature.map { String(format: "%02x", $0) }.joined()
        
        let authorization = "AWS4-HMAC-SHA256 Credential=\(config.accessKey)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signatureHex)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }
}
