import Foundation
import CloudDriveContracts
import CloudDriveSupport

public struct Pan123CreateFileData: Codable, Sendable {
    public let fileID: Int64?
    public let reuse: Bool?           // 是否秒传成功
    public let preuploadID: String?   // 预上传 ID
    public let sliceSize: Int?        // 分片大小
    public let servers: [String]?     // 上传域名列表
    
    public init(
        fileID: Int64? = nil,
        reuse: Bool? = nil,
        preuploadID: String? = nil,
        sliceSize: Int? = nil,
        servers: [String]? = nil
    ) {
        self.fileID = fileID
        self.reuse = reuse
        self.preuploadID = preuploadID
        self.sliceSize = sliceSize
        self.servers = servers
    }
}
