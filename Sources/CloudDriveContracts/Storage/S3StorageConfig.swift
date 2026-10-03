import Foundation

public struct S3StorageConfig: Codable, Hashable, Sendable {
    public var endpoint: String         // 自定义 endpoint (例如 https://s3.amazonaws.com 或 http://192.168.1.100:9000)
    public var region: String           // 区域 (例如 us-east-1, auto, cn-north-1)
    public var bucket: String           // 存储桶名称
    public var accessKey: String        // Access Key ID
    public var secretKey: String        // Secret Access Key
    public var usePathStyle: Bool       // 是否使用路径风格 (true: endpoint/bucket/key, false: bucket.endpoint/key，MinIO 通常需要 true)
    public var rootPrefix: String       // 根目录前缀 (可选，如 my-vault)
    
    public init(
        endpoint: String = "https://s3.amazonaws.com",
        region: String = "us-east-1",
        bucket: String,
        accessKey: String,
        secretKey: String,
        usePathStyle: Bool = false,
        rootPrefix: String = ""
    ) {
        self.endpoint = endpoint
        self.region = region.isEmpty ? "us-east-1" : region
        self.bucket = bucket
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.usePathStyle = usePathStyle
        self.rootPrefix = rootPrefix
    }
}
