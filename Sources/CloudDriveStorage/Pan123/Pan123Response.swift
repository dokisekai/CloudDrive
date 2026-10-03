import Foundation
import CloudDriveContracts
import CloudDriveSupport

public struct Pan123Response<T: Decodable>: Decodable {
    public let code: Int
    public let message: String
    public let data: T?
    public let xTraceID: String?
    
    enum CodingKeys: String, CodingKey {
        case code
        case message
        case data
        case xTraceID = "x-traceID"
    }
    
    public var isSuccess: Bool {
        return code == 0
    }
}
